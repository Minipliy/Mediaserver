#!/usr/bin/env python3
"""Prepare optional HLS copies, so video adapts to a slow connection.

Never rewrites originals. Copies live in the hidden folder .miniply-hls of the
library and use extra disk space. Without a copy the app plays the normal file.

Start with --dry-run for the needed space, and --benchmark for the speed on
this machine; converting a collection on a small computer can take days.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

_spec = importlib.util.spec_from_file_location("prepare_media", Path(__file__).resolve().with_name("prepare-media.py"))
media = importlib.util.module_from_spec(_spec)
sys.modules["prepare_media"] = media
_spec.loader.exec_module(media)
PreparationError = media.PreparationError

CACHE = ".miniply-hls"
PROFILE_REVISION = 1
SEGMENT_SECONDS = 6
# Height and video bitrate of the converted steps.
LADDER = ((1080, 5_000_000), (720, 2_800_000), (480, 1_200_000))
AUDIO_BITRATE = 128_000


def renditions_for(width: int, height: int, *, copy_video: bool, allow_copy: bool) -> list[dict]:
    """Best first. An H.264 source is reused as the top step, which costs no
    conversion; a portrait video is scaled by its shorter side."""
    short_side = min(width, height)
    top = min(short_side, 1080)

    def converted(target: int, bitrate: int) -> dict:
        scale = target / short_side
        even = lambda value: max(2, int(round(value * scale / 2)) * 2)
        return {"copy": False, "height": even(height), "width": even(width), "bitrate": bitrate}

    if copy_video and allow_copy:
        result = [{"copy": True, "height": height, "width": width}]
    else:
        fitting = [bitrate for target, bitrate in LADDER if target <= top]
        result = [converted(top, fitting[0] if fitting else LADDER[-1][1])]
    return result + [converted(target, bitrate) for target, bitrate in LADDER if target < top]


def estimated_bytes(renditions: list[dict], duration: float, source_bytes: int) -> int:
    total = 0
    for rendition in renditions:
        total += source_bytes if rendition["copy"] else int((rendition["bitrate"] + AUDIO_BITRATE) / 8 * duration)
    return total


def encode_arguments(rendition: dict, plan: media.Plan, threads: int, seconds: float | None = None) -> list[str]:
    result = ["-map", f"0:{plan.video_index}"]
    if plan.audio_index is not None:
        result += ["-map", f"0:{plan.audio_index}", "-c:a", "aac", "-b:a", str(AUDIO_BITRATE), "-ac", "2", "-ar", "48000"]
    if seconds is not None:
        result += ["-t", str(seconds)]
    if rendition["copy"]:
        result += ["-c:v", "copy", "-bsf:v", "h264_mp4toannexb"]
    else:
        filters = []
        if plan.hdr:
            filters += ["zscale=transfer=linear:npl=100", "format=gbrpf32le", "zscale=primaries=bt709",
                        "tonemap=tonemap=hable:desat=0", "zscale=transfer=bt709:matrix=bt709:range=tv"]
        filters += [f"scale={rendition['width']}:{rendition['height']}", "format=yuv420p"]
        bitrate = rendition["bitrate"]
        result += ["-vf", ",".join(filters), "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "4.1",
                   "-b:v", str(bitrate), "-maxrate", str(int(bitrate * 1.3)), "-bufsize", str(bitrate * 2),
                   "-sc_threshold", "0", "-force_key_frames", f"expr:gte(t,n_forced*{SEGMENT_SECONDS})",
                   "-threads", str(threads), "-filter_threads", str(threads)]
    return result + ["-sn", "-dn", "-f", "hls", "-hls_time", str(SEGMENT_SECONDS), "-hls_playlist_type", "vod",
                     "-hls_segment_type", "mpegts", "-hls_segment_filename", "seg%05d.ts", "index.m3u8"]


def read_playlist(folder: int) -> list[tuple[float, str]]:
    descriptor = os.open("index.m3u8", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=folder)
    with os.fdopen(descriptor, encoding="utf-8") as stream:
        text = stream.read()
    if "#EXT-X-ENDLIST" not in text:
        raise PreparationError("Die erzeugte Wiedergabeliste ist unvollständig.")
    segments = re.findall(r"#EXTINF:([0-9.]+),[^\n]*\n([^\n]+)", text)
    if not segments:
        raise PreparationError("Die erzeugte Wiedergabeliste enthält keine Segmente.")
    return [(float(length), name) for length, name in segments]


def stream_codecs(ffprobe: str, folder: int, name: str) -> str:
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=folder)
    try:
        data = media.run([ffprobe, "-v", "error", "-protocol_whitelist", "file", "-show_entries", "stream=codec_type,codec_name,profile,level",
                          "-of", "json", f"/dev/fd/{descriptor}"], pass_fds=(descriptor,), timeout=120)
    finally:
        os.close(descriptor)
    streams = json.loads(data).get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video is None or video.get("codec_name") != "h264":
        raise PreparationError("Das erzeugte Segment enthält kein H.264-Video.")
    profile = {"Baseline": "42E0", "Constrained Baseline": "42E0", "Main": "4D40", "High": "6400"}.get(video.get("profile"), "6400")
    codecs = [f"avc1.{profile}{int(video.get('level', 41)):02X}"]
    if any(s.get("codec_type") == "audio" for s in streams):
        codecs.append("mp4a.40.2")
    return ",".join(codecs)


def master_playlist(entries: list[dict]) -> str:
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for index, entry in enumerate(sorted(entries, key=lambda item: item["bandwidth"])):
        lines.append(f"#EXT-X-STREAM-INF:BANDWIDTH={entry['bandwidth']},AVERAGE-BANDWIDTH={entry['average']},"
                     f"RESOLUTION={entry['width']}x{entry['height']},CODECS=\"{entry['codecs']}\"")
        lines.append(f"{entry['name']}/index.m3u8")
    return "\n".join(lines) + "\n"


def build(source: int, stage: int, plan: media.Plan, renditions: list[dict], args: argparse.Namespace) -> tuple[list[dict], int]:
    entries: list[dict] = []
    total = 0
    for index, rendition in enumerate(renditions):
        name = f"v{index}"
        os.mkdir(name, mode=0o755, dir_fd=stage)
        folder = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=stage)
        try:
            os.lseek(source, 0, os.SEEK_SET)
            command = [args.ffmpeg, "-nostdin", "-v", "error", "-xerror", "-y", "-protocol_whitelist", "file",
                       "-format_whitelist", media.DEMUXERS, "-threads", str(args.threads), "-i", f"/dev/fd/{source}"]
            command += encode_arguments(rendition, plan, args.threads)
            media.run(command, pass_fds=(source, folder), timeout=args.timeout, directory_fd=folder)
            segments = read_playlist(folder)
            peak = size = length = 0
            for seconds, segment in segments:
                metadata = os.stat(segment, dir_fd=folder, follow_symlinks=False)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_size == 0:
                    raise PreparationError("Ein erzeugtes Segment fehlt oder ist leer.")
                size += metadata.st_size
                length += seconds
                if seconds > 0:
                    peak = max(peak, int(metadata.st_size * 8 / seconds))
            total += size
            entries.append({"name": name, "bandwidth": max(peak, 1), "average": int(size * 8 / max(length, 0.001)),
                            "width": rendition["width"], "height": rendition["height"],
                            "codecs": stream_codecs(args.ffprobe, folder, segments[0][1])})
            os.fsync(folder)
        finally:
            os.close(folder)
    return entries, total


def is_current(cache: int, identifier: str, signature: dict) -> bool:
    try:
        directory = os.open(identifier, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cache)
    except OSError:
        return False
    try:
        descriptor = os.open("manifest.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(descriptor, encoding="utf-8") as stream:
            manifest = json.loads(stream.read(16384))
        return all(manifest.get(key) == value for key, value in signature.items()) and manifest.get("revision") == PROFILE_REVISION
    except (OSError, ValueError, AttributeError):
        return False
    finally:
        os.close(directory)


def video_size(info: dict, plan: media.Plan) -> tuple[int, int, float]:
    stream = next(s for s in info["streams"] if s.get("index") == plan.video_index)
    duration = float(info.get("format", {}).get("duration") or 0)
    if not duration or not stream.get("width") or not stream.get("height"):
        raise PreparationError("Länge oder Bildgröße der Quelle ist unbekannt.")
    return stream["width"], stream["height"], duration


def rotation_of(ffprobe: str, source: int, plan: media.Plan) -> int:
    """Quarter turns are stored beside the picture, for example by iPhones."""
    os.lseek(source, 0, os.SEEK_SET)
    try:
        data = media.run([ffprobe, "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", media.DEMUXERS,
                          "-select_streams", str(plan.video_index),
                          "-show_entries", "stream_side_data=rotation:stream_tags=rotate", "-of", "json", f"/dev/fd/{source}"],
                         pass_fds=(source,), timeout=60)
    finally:
        os.lseek(source, 0, os.SEEK_SET)
    streams = json.loads(data).get("streams", [])
    if not streams:
        return 0
    value = streams[0].get("tags", {}).get("rotate", 0)
    for entry in streams[0].get("side_data_list", []):
        value = entry.get("rotation", value)
    try:
        return int(round(float(value))) % 360
    except (TypeError, ValueError):
        return 0


def displayed_renditions(info: dict, plan: media.Plan, rotation: int, allow_copy: bool) -> list[dict]:
    """MPEG-TS cannot store a rotation, so such a source is never reused.
    FFmpeg turns the picture while converting; sizes describe the result."""
    width, height, _ = video_size(info, plan)
    if rotation in (90, 270):
        width, height = height, width
    return renditions_for(width, height, copy_video=plan.copy_video and rotation == 0, allow_copy=allow_copy)


def prepare(root: int, cache: int | None, path: str, args: argparse.Namespace) -> tuple[str, int]:
    with media.open_source(root, path) as source:
        before = os.fstat(source)
        signature = media.source_signature(path, before)
        identifier = hashlib.sha256(path.encode("utf-8")).hexdigest()
        if cache is not None and not args.force and is_current(cache, identifier, signature):
            return "vorhanden", 0
        info = media.probe(args.ffprobe, source)
        plan = media.plan_for(path, info)
        _, _, duration = video_size(info, plan)
        renditions = displayed_renditions(info, plan, rotation_of(args.ffprobe, source, plan), not args.no_copy)
        needed = estimated_bytes(renditions, duration, before.st_size)
        if args.dry_run:
            steps = ", ".join("Original" if r["copy"] else f"{r['height']}p" for r in renditions)
            return f"würde erzeugen ({steps})", needed
        volume = os.fstatvfs(cache)
        if volume.f_bavail * volume.f_frsize < needed + args.reserve_mb * 1_000_000:
            raise PreparationError("Zu wenig freier Platz für diese HLS-Kopie.")
        stage_name = ".work-" + uuid.uuid4().hex
        os.mkdir(stage_name, mode=0o755, dir_fd=cache)
        stage = os.open(stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cache)
        try:
            entries, total = build(source, stage, plan, renditions, args)
            with media.open_source(root, path) as current:
                after = os.fstat(current)
                if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                    raise PreparationError("Die Quelldatei wurde während der Aufbereitung verändert; bitte erneut starten.")
            for name, text in (("master.m3u8", master_playlist(entries)),
                               ("manifest.json", json.dumps({**signature, "revision": PROFILE_REVISION, "bytes": total}, ensure_ascii=False))):
                descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=stage)
                with os.fdopen(descriptor, "w", encoding="utf-8") as target:
                    target.write(text)
                    target.flush()
                    os.fsync(target.fileno())
            # A previous copy leaves first, so the name never shows a mix of both.
            old_name = None
            if _exists(cache, identifier):
                old_name = ".old-" + uuid.uuid4().hex
                os.rename(identifier, old_name, src_dir_fd=cache, dst_dir_fd=cache)
            os.rename(stage_name, identifier, src_dir_fd=cache, dst_dir_fd=cache)
            stage_name = None
            if old_name:
                shutil.rmtree(old_name, dir_fd=cache)
            return "vorbereitet", total
        finally:
            os.close(stage)
            if stage_name:
                shutil.rmtree(stage_name, dir_fd=cache, ignore_errors=True)


def _exists(directory: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def benchmark(root: int, path: str, args: argparse.Namespace, seconds: int = 30) -> None:
    """Convert a short part of one file into a temporary folder, then remove it."""
    with media.open_source(root, path) as source:
        info = media.probe(args.ffprobe, source)
        plan = media.plan_for(path, info)
        renditions = displayed_renditions(info, plan, rotation_of(args.ffprobe, source, plan), False)
        print(f"Probe: {renditions[0]['width']}x{renditions[0]['height']}, {seconds} s, {args.threads} Thread(s)", flush=True)
        for rendition in renditions:
            with tempfile.TemporaryDirectory(prefix="miniply-hls-") as folder:
                os.lseek(source, 0, os.SEEK_SET)
                command = [args.ffmpeg, "-nostdin", "-v", "error", "-y", "-protocol_whitelist", "file",
                           "-format_whitelist", media.DEMUXERS, "-threads", str(args.threads), "-i", f"/dev/fd/{source}"]
                command += encode_arguments(rendition, plan, args.threads, seconds=seconds)
                started = time.monotonic()
                subprocess.run(command, pass_fds=(source,), cwd=folder, check=True, stdin=subprocess.DEVNULL, timeout=args.timeout)
                took = max(time.monotonic() - started, 0.001)
            print(f"{rendition['height']}p: {seconds / took:.2f}x Echtzeit", flush=True)


def remove_leftovers(cache: int) -> None:
    """Folders of a run that ended abruptly. Only call while holding the lock."""
    for name in os.listdir(cache):
        if name.startswith((".work-", ".old-")):
            shutil.rmtree(name, dir_fd=cache, ignore_errors=True)


def stop_cleanly(number, frame):
    # Python skips `finally` on a plain SIGTERM, which would leave a work
    # folder behind. subprocess.run ends FFmpeg when this passes through it.
    raise SystemExit(128 + number)


def main() -> int:
    signal.signal(signal.SIGTERM, stop_cleanly)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Medienverzeichnis, zum Beispiel /srv/media")
    parser.add_argument("--path", action="append", default=[], help="Nur diesen relativen Dateipfad bearbeiten; wiederholbar")
    parser.add_argument("--dry-run", action="store_true", help="Nur den nötigen Platz anzeigen")
    parser.add_argument("--benchmark", action="store_true", help="30 Sekunden der ersten Datei umwandeln und die Geschwindigkeit anzeigen")
    parser.add_argument("--no-copy", action="store_true", help="Auch H.264-Quellen umwandeln statt sie als oberste Stufe zu übernehmen")
    parser.add_argument("--force", action="store_true", help="Vorhandene Kopien neu erzeugen")
    parser.add_argument("--threads", type=int, default=1, help="FFmpeg-Threads; Dateien werden nacheinander verarbeitet")
    parser.add_argument("--reserve-mb", type=int, default=2048, help="Mindestens so viel Speicher frei lassen")
    parser.add_argument("--timeout", type=int, default=172800, help="Maximale Dauer je Stufe in Sekunden")
    parser.add_argument("--ffmpeg", default="ffmpeg", help=argparse.SUPPRESS)
    parser.add_argument("--ffprobe", default="ffprobe", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.threads < 1 or args.threads > 16 or args.timeout < 1 or args.reserve_mb < 0:
        parser.error("Threads müssen 1–16 sein; Zeitlimit positiv und Reserve nicht negativ.")
    for program in (args.ffmpeg, args.ffprobe):
        if shutil.which(program) is None:
            parser.error(f"{program} fehlt. macOS: brew install ffmpeg; Raspberry Pi: sudo apt install ffmpeg")
    root = cache = lock = None
    try:
        args.root = args.root.resolve(strict=True)
        root = os.open(args.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        paths = [path for path in media.candidates(args.root, args.path) if media.kind_for(path) == "video"]
        if args.benchmark:
            if not paths:
                raise PreparationError("Keine Videodatei für die Probe gefunden.")
            benchmark(root, paths[0], args)
            return 0
        if not args.dry_run:
            cache = media.mkdir_open(root, CACHE)
            lock = os.open(".prepare.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644, dir_fd=cache)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise PreparationError("Für dieses Medienverzeichnis läuft bereits eine HLS-Aufbereitung.") from error
            remove_leftovers(cache)
        failures = 0
        total = 0
        for path in paths:
            try:
                result, size = prepare(root, cache, path, args)
                total += size
                print(f"{result}: {path}", flush=True)
            except (media.PreparationError, OSError, subprocess.SubprocessError, ValueError, StopIteration) as error:
                failures += 1
                print(f"Fehler: {path}: {error}", file=sys.stderr, flush=True)
        print(f"{'Geschätzter Platzbedarf' if args.dry_run else 'Neu belegt'}: {total / 1e9:.1f} GB", flush=True)
        return 1 if failures else 0
    except (PreparationError, OSError) as error:
        print(f"Fehler: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    finally:
        for descriptor in (lock, cache, root):
            if descriptor is not None:
                os.close(descriptor)


if __name__ == "__main__":
    sys.exit(main())
