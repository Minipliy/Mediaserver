#!/usr/bin/env python3
"""Prepare optional iPhone playback copies; never rewrite original media.

Requires ffmpeg + ffprobe. Outputs are hidden from the normal library scanner.
Only local, self-contained media files are accepted; playlists/network inputs
are deliberately excluded. Run on the Mac or as a single background Pi job.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import time
import uuid

CACHE = ".miniply-playback"
AUDIO = frozenset("mp1 mp2 mp3 m4a m4b m4r aac adts flac wav wave aiff aif aifc alac ogg oga opus spx weba caf ape wma wv ac3 eac3 dts amr au snd".split())
VIDEO = frozenset("mp4 m4v mov qt mkv avi webm mpeg mpg mpe m1v m2v vob ts mts m2ts ogv 3gp 3gpp 3g2 wmv asf flv".split())
DEMUXERS = "mov,mp3,aac,flac,wav,aiff,caf,ogg,matroska,webm,avi,mpeg,mpegvideo,mpegts,asf,flv,ape,wv,ac3,eac3,dts,amr,au"
DIRECT_AUDIO = {
    "mp3": {"mp3"}, "aac": {"aac"}, "flac": {"flac"},
    "m4a": {"aac", "alac"}, "m4b": {"aac", "alac"}, "m4r": {"aac", "alac"}, "adts": {"aac"}, "alac": {"alac"},
    "wav": {"pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"},
    "wave": {"pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"},
    "aiff": {"pcm_s16be", "pcm_s24be", "pcm_s32be"},
    "aif": {"pcm_s16be", "pcm_s24be", "pcm_s32be"},
    "aifc": {"pcm_s16be", "pcm_s24be", "pcm_s32be"},
    "caf": {"alac", "pcm_s16le", "pcm_s24le", "pcm_f32le"},
}


class PreparationError(Exception):
    pass


def kind_for(path: str) -> str | None:
    extension = PurePosixPath(path).suffix[1:].lower()
    return "audio" if extension in AUDIO else "video" if extension in VIDEO else None


def relative_parts(path: str) -> tuple[str, ...]:
    parts = path.split("/")
    if not path or any(not part or part in {".", ".."} or part.startswith(".") for part in parts):
        raise PreparationError("Nur sichtbare relative Dateipfade innerhalb der Mediathek sind erlaubt.")
    return tuple(parts)


@contextmanager
def open_source(root_fd: int, path: str):
    """Anchor every path component; a symlink/FIFO swap must not escape or block."""
    parts = relative_parts(path)
    directory = os.dup(root_fd)
    source = None
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        source = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        if not stat.S_ISREG(os.fstat(source).st_mode):
            raise PreparationError("Die Quelle ist keine reguläre Datei.")
        yield source
    finally:
        if source is not None:
            os.close(source)
        os.close(directory)


def run(command: list[str], *, pass_fds: tuple[int, ...], timeout: int,
        directory_fd: int | None = None) -> str:
    try:
        # This CLI is single-threaded. Anchor the child's working directory to
        # the already-open stage rather than following a replaceable path.
        # macOS cannot chdir via /dev/fd/N or traverse /dev/fd/N/filename.
        child_directory = (lambda: os.fchdir(directory_fd)) if directory_fd is not None else None
        result = subprocess.run(command, pass_fds=pass_fds, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, errors="replace", timeout=timeout,
                                preexec_fn=child_directory)
    except subprocess.TimeoutExpired as error:
        raise PreparationError("Zeitlimit erreicht; die unfertige Kopie wird verworfen.") from error
    # Both tools run at loglevel error. ffprobe (and some decoder paths) can
    # report damaged packets yet exit zero; never publish that as a valid copy.
    if result.returncode or result.stderr.strip():
        # ffmpeg's diagnostics can contain paths but never connection credentials.
        detail = result.stderr.strip()[-2000:]
        raise PreparationError(detail or "FFmpeg konnte diese Datei nicht verarbeiten.")
    return result.stdout


def probe(binary: str, descriptor: int) -> dict:
    # /dev/fd opens share their offset on macOS. A completed ffprobe must not
    # leave the later decoder at EOF (or a subsequent probe halfway through).
    os.lseek(descriptor, 0, os.SEEK_SET)
    try:
        data = run([binary, "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", DEMUXERS,
                    "-show_entries", "format=format_name,duration:stream=index,codec_type,codec_name,codec_tag_string,pix_fmt,width,height,channels,sample_rate,color_transfer:stream_disposition=attached_pic,default",
                    "-of", "json", f"/dev/fd/{descriptor}"], pass_fds=(descriptor,), timeout=60)
    finally:
        os.lseek(descriptor, 0, os.SEEK_SET)
    try:
        return json.loads(data)
    except (json.JSONDecodeError, TypeError) as error:
        raise PreparationError("Ungültige Antwort von ffprobe.") from error


@dataclass(frozen=True)
class Plan:
    kind: str
    direct: bool
    copy_video: bool = False
    hdr: bool = False
    video_index: int = 0
    audio_index: int | None = None


def plan_for(path: str, info: dict) -> Plan:
    kind = kind_for(path)
    streams = info.get("streams", [])
    def selected(stream_type: str) -> dict | None:
        candidates = [s for s in streams if s.get("codec_type") == stream_type
                      and not s.get("disposition", {}).get("attached_pic")]
        return next((s for s in candidates if s.get("disposition", {}).get("default")),
                    candidates[0] if candidates else None)
    audio, video = selected("audio"), selected("video")
    extension = PurePosixPath(path).suffix[1:].lower()
    if kind == "audio":
        if audio is None:
            raise PreparationError("Keine Audiospur in der Audiodatei gefunden.")
        direct = audio.get("codec_name") in DIRECT_AUDIO.get(extension, set()) and audio.get("channels", 99) <= 2
        return Plan(kind="audio", direct=direct, audio_index=audio["index"])
    if kind != "video" or video is None:
        raise PreparationError("Keine eigenständige Videospur gefunden.")
    width, height = video.get("width", 0), video.get("height", 0)
    h264 = (video.get("codec_name") == "h264" and video.get("pix_fmt") in {"yuv420p", "yuvj420p"}
            and width > 0 and height > 0 and max(width, height) <= 1920 and min(width, height) <= 1080)
    hevc = video.get("codec_name") == "hevc" and video.get("codec_tag_string") == "hvc1"
    safe_audio = audio is None or (audio.get("codec_name") == "aac" and audio.get("channels", 99) <= 2)
    direct = extension in {"mp4", "m4v", "mov", "qt"} and (h264 or hevc) and safe_audio
    return Plan(kind="video", direct=direct, copy_video=h264,
                hdr=video.get("color_transfer") in {"smpte2084", "arib-std-b67"},
                video_index=video["index"], audio_index=audio["index"] if audio else None)


def conversion_arguments(plan: Plan, *, audio_codec: str, threads: int) -> list[str]:
    result = ["-map_metadata", "0", "-map_chapters", "0"]
    if plan.kind == "audio":
        result += ["-map", f"0:{plan.audio_index}", "-vn", "-c:a", audio_codec]
        if audio_codec == "aac":
            result += ["-ac", "2", "-ar", "48000", "-b:a", "256k"]
    else:
        result += ["-map", f"0:{plan.video_index}"]
        if plan.audio_index is not None:
            result += ["-map", f"0:{plan.audio_index}", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000"]
        if plan.copy_video:
            result += ["-c:v", "copy"]
        else:
            filters = []
            if plan.hdr:
                filters += ["zscale=transfer=linear:npl=100", "format=gbrpf32le", "zscale=primaries=bt709",
                            "tonemap=tonemap=hable:desat=0", "zscale=transfer=bt709:matrix=bt709:range=tv"]
            filters += ["scale=w='if(gte(iw,ih),min(1920,iw),min(1080,iw))':h='if(gte(iw,ih),min(1080,ih),min(1920,ih))':force_original_aspect_ratio=decrease:force_divisible_by=2",
                        "fps=30", "format=yuv420p"]
            result += ["-vf", ",".join(filters), "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                       "-profile:v", "high", "-level:v", "4.1", "-maxrate", "12M", "-bufsize", "24M",
                       "-threads", str(threads), "-filter_threads", str(threads)]
        result += ["-tag:v", "avc1"]
    return result + ["-sn", "-dn", "-movflags", "+faststart", "-f", "mp4"]


def mkdir_open(parent: int, name: str) -> int:
    try:
        os.mkdir(name, mode=0o755, dir_fd=parent)
    except FileExistsError:
        pass
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)


def source_signature(path: str, metadata: os.stat_result) -> dict:
    return {"version": 1, "source_path": path, "source_bytes": metadata.st_size,
            "source_modified_ns": metadata.st_mtime_ns}


def is_current(cache: int, identifier: str, signature: dict, profile: dict) -> bool:
    directory = manifest_fd = media_fd = None
    try:
        directory = os.open(identifier, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cache)
        manifest_fd = os.open("manifest.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        if not stat.S_ISREG(os.fstat(manifest_fd).st_mode) or os.fstat(manifest_fd).st_size > 16384:
            return False
        manifest = json.loads(os.read(manifest_fd, 16385))
        if any(manifest.get(key) != value for key, value in signature.items()) or manifest.get("profile") != profile:
            return False
        if manifest.get("filename") not in {"playback.mp4", "playback.m4a"}:
            return False
        media_fd = os.open(manifest["filename"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        metadata = os.fstat(media_fd)
        return stat.S_ISREG(metadata.st_mode) and metadata.st_size > 0 and metadata.st_size == manifest.get("bytes")
    except (OSError, ValueError, TypeError, AttributeError):
        return False
    finally:
        for descriptor in (media_fd, manifest_fd, directory):
            if descriptor is not None:
                os.close(descriptor)


def prepare(root: int, cache: int | None, path: str, args: argparse.Namespace) -> str:
    with open_source(root, path) as source:
        before = os.fstat(source)
        signature = source_signature(path, before)
        profile = {"revision": 2, "audio_codec": args.audio_codec}
        identifier = hashlib.sha256(path.encode("utf-8")).hexdigest()
        if cache is not None and not args.force and is_current(cache, identifier, signature, profile):
            return "vorhanden"
        plan = plan_for(path, probe(args.ffprobe, source))
        if plan.direct and not args.all:
            return "direkt"
        if args.dry_run:
            return "würde vorbereiten"
        if os.fstatvfs(cache).f_bavail * os.fstatvfs(cache).f_frsize < max(before.st_size, 16_000_000) + args.reserve_mb * 1_000_000:
            raise PreparationError("Zu wenig freier Platz für eine zusätzliche Wiedergabekopie.")
        stage_name = ".work-" + uuid.uuid4().hex
        os.mkdir(stage_name, mode=0o700, dir_fd=cache)
        stage = os.open(stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cache)
        filename = "playback.m4a" if plan.kind == "audio" else "playback.mp4"
        destination = None
        manifest_name = ".manifest-" + uuid.uuid4().hex
        try:
            command = [args.ffmpeg, "-nostdin", "-v", "error", "-xerror", "-y", "-protocol_whitelist", "file",
                       "-format_whitelist", DEMUXERS, "-threads", str(args.threads), "-i", f"/dev/fd/{source}"]
            command += conversion_arguments(plan, audio_codec=args.audio_codec, threads=args.threads)
            # Faststart reopens the output for its second pass. /dev/fd/N would
            # share read/write offsets on macOS and silently corrupt the file.
            # A plain name inside the anchored private stage has independent
            # handles and does not resolve the source/cache path again.
            command += [filename]
            run(command, pass_fds=(source, stage), timeout=args.timeout, directory_fd=stage)
            with open_source(stage, filename) as output:
                size = os.fstat(output).st_size
                checked = probe(args.ffprobe, output)
                if size <= 0 or (plan.kind == "video" and not any(s.get("codec_name") == "h264" for s in checked.get("streams", []))):
                    raise PreparationError("Die erzeugte Kopie enthält kein gültiges Wiedergabeformat.")
                if plan.kind == "audio" and not any(s.get("codec_name") == args.audio_codec for s in checked.get("streams", [])):
                    raise PreparationError("Die erzeugte Audiospur ist ungültig.")
                os.fsync(output)
            # Reopen the indexed name as well: the original may have been replaced
            # while its already-open descriptor was being decoded.
            with open_source(root, path) as current:
                after = os.fstat(current)
                if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                    raise PreparationError("Die Quelldatei wurde während der Aufbereitung verändert; bitte erneut starten.")
            destination = mkdir_open(cache, identifier)
            manifest = {**signature, "filename": filename, "bytes": size, "profile": profile}
            descriptor = os.open(manifest_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=destination)
            with os.fdopen(descriptor, "w", encoding="utf-8") as target:
                json.dump(manifest, target, ensure_ascii=False)
                target.flush()
                os.fsync(target.fileno())
            os.replace(filename, filename, src_dir_fd=stage, dst_dir_fd=destination)
            os.replace(manifest_name, "manifest.json", src_dir_fd=destination, dst_dir_fd=destination)
            return "vorbereitet"
        finally:
            if destination is not None:
                try:
                    os.unlink(manifest_name, dir_fd=destination)
                except FileNotFoundError:
                    pass
                os.close(destination)
            for name in os.listdir(stage):
                os.unlink(name, dir_fd=stage)
            os.close(stage)
            os.rmdir(stage_name, dir_fd=cache)


def candidates(root: Path, paths: list[str]):
    if paths:
        for path in paths:
            relative_parts(path)
            if kind_for(path) is None:
                raise PreparationError(f"Kein unterstütztes Medienformat: {path}")
            yield path
        return
    visited = 0
    for folder, directories, files in os.walk(root, followlinks=False):
        relative = Path(folder).relative_to(root)
        directories[:] = sorted(name for name in directories if not name.startswith(".") and not (Path(folder) / name).is_symlink())
        if len(relative.parts) >= 64:
            directories.clear()
        for name in sorted(files):
            visited += 1
            if visited > 100_000:
                raise PreparationError("Scanlimit von 100.000 Dateien erreicht. Teilordner mit --path auswählen.")
            path = (relative / name).as_posix()
            if not name.startswith(".") and kind_for(path) and not (Path(folder) / name).is_symlink():
                yield path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Medienverzeichnis, zum Beispiel ./media oder /srv/media")
    parser.add_argument("--path", action="append", default=[], help="Nur diesen relativen Dateipfad bearbeiten; wiederholbar")
    parser.add_argument("--dry-run", action="store_true", help="Dateien prüfen und Änderungen nur anzeigen")
    parser.add_argument("--all", action="store_true", help="Auch bereits direkt abspielbare Formate aufbereiten")
    parser.add_argument("--force", action="store_true", help="Vorhandene Wiedergabekopien erneut erzeugen")
    parser.add_argument("--audio-codec", choices=["aac", "alac"], default="aac", help="AAC 256 kbit/s (Standard) oder größeres ALAC")
    parser.add_argument("--threads", type=int, default=2, help="FFmpeg-Threads; Dateien werden nacheinander verarbeitet")
    parser.add_argument("--reserve-mb", type=int, default=256, help="Freien Speicher zusätzlich zur geschätzten Kopie reservieren")
    parser.add_argument("--timeout", type=int, default=21600, help="Maximale Aufbereitungsdauer je Datei in Sekunden")
    parser.add_argument("--watch", type=int, default=0, metavar="SEKUNDEN", help="Erneut scannen, mindestens alle 15 Sekunden; Ctrl+C beendet")
    parser.add_argument("--ffmpeg", default="ffmpeg", help=argparse.SUPPRESS)
    parser.add_argument("--ffprobe", default="ffprobe", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.threads < 1 or args.threads > 16 or args.timeout < 1 or args.reserve_mb < 0 or (args.watch and args.watch < 15):
        parser.error("Threads müssen 1–16 sein; Zeitlimit positiv, Reserve nicht negativ und --watch mindestens 15.")
    for program in (args.ffmpeg, args.ffprobe):
        if shutil.which(program) is None:
            parser.error(f"{program} fehlt. macOS: brew install ffmpeg; Raspberry Pi: sudo apt install ffmpeg")
    root = cache = lock = None
    try:
        # A user-selected root can itself be a mounted share; children never follow symlinks.
        args.root = args.root.resolve(strict=True)
        root = os.open(args.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if not args.dry_run:
            cache = mkdir_open(root, CACHE)
            lock = os.open(".prepare.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644, dir_fd=cache)
            if not stat.S_ISREG(os.fstat(lock).st_mode):
                raise PreparationError("Ungültige Sperrdatei im Wiedergabeverzeichnis.")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise PreparationError("Für dieses Medienverzeichnis läuft bereits eine Aufbereitung.") from error
        while True:
            failures = 0
            for path in candidates(args.root, args.path):
                try:
                    result = prepare(root, cache, path, args)
                    print(f"{result}: {path}", flush=True)
                except (PreparationError, OSError) as error:
                    failures += 1
                    print(f"Fehler: {path}: {error}", file=sys.stderr, flush=True)
            if not args.watch:
                return 1 if failures else 0
            time.sleep(args.watch)
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
