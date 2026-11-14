#!/usr/bin/env python3
"""Exercise real ffmpeg preparation with disposable media; no user files/network.

Use --keep-fixtures build/format-fixtures to keep the two prepared files for
MINIPLY_PLAYBACK_FIXTURES=<absolute directory> scripts/check-ios-playback.sh.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen
from urllib.parse import unquote


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-fixtures", type=Path)
    parser.add_argument("--server-bin", type=Path, help="Optional: echte Router-/Streamingprüfung mit diesem lokalen Backend-Binary")
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        print("FFmpeg/ffprobe fehlen. Installation: brew install ffmpeg (Mac) bzw. apt install ffmpeg (Pi).", file=sys.stderr)
        return 2
    prepare = Path(__file__).resolve().with_name("prepare-media.py")
    checks = 0

    def require(value: bool, description: str):
        nonlocal checks
        if not value:
            raise AssertionError(description)
        checks += 1
        print("PASS " + description, flush=True)

    def run(command: list[str], *, ok: bool = True, timeout: int = 60):
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        if ok and result.returncode:
            raise AssertionError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
        return result

    def inspect(path: Path):
        return json.loads(run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]).stdout)

    with tempfile.TemporaryDirectory(prefix="mediaserver-formats-") as temporary:
        work = Path(temporary)
        root = work / "library"
        root.mkdir()
        music, video = root / "Musik", root / "Filme"
        music.mkdir(); video.mkdir()
        ogg = music / "Titel mit Umlaut ä.OGG"
        avi = video / "Alter Film.AVI"
        mov = video / "iPhone.MOV"
        flac = music / "Verlustfrei.FLAC"
        aiff = music / "24 Bit.aiff"
        run([ffmpeg, "-v", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "libopus", str(ogg)])
        run([ffmpeg, "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=15:duration=2",
             "-f", "lavfi", "-i", "sine=frequency=300:duration=2", "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest", str(avi)])
        run([ffmpeg, "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=15:duration=2",
             "-f", "lavfi", "-i", "sine=frequency=300:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", str(mov)])
        run([ffmpeg, "-v", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=500:duration=2", "-c:a", "flac", str(flac)])
        run([ffmpeg, "-v", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=500:duration=2", "-c:a", "pcm_s24be", str(aiff)])
        originals = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (ogg, avi, mov, flac, aiff)}

        def prepare_run(*options: str, ok: bool = True, selected_root: Path = root):
            return run([sys.executable, str(prepare), str(selected_root), *options], ok=ok)

        def manifest(path: Path):
            relative = path.relative_to(root).as_posix()
            directory = root / ".miniply-playback" / hashlib.sha256(relative.encode("utf-8")).hexdigest()
            metadata = json.loads((directory / "manifest.json").read_text())
            return directory, metadata

        preview = prepare_run("--dry-run")
        require(preview.returncode == 0 and not (root / ".miniply-playback").exists(), "Dry run leaves original library and cache untouched")
        actual = prepare_run()
        require(actual.returncode == 0, "Unsupported OGG/Opus and AVI/MPEG4 sources are prepared")
        require(not (root / ".miniply-playback" / hashlib.sha256(mov.relative_to(root).as_posix().encode()).hexdigest()).exists(), "Native H264/AAC MOV is served directly")
        require(not (root / ".miniply-playback" / hashlib.sha256(flac.relative_to(root).as_posix().encode()).hexdigest()).exists(), "Native FLAC remains direct and unchanged")
        audio_directory, audio = manifest(ogg)
        video_directory, movie = manifest(avi)
        prepared_audio = audio_directory / audio["filename"]
        prepared_video = video_directory / movie["filename"]
        require(audio["filename"] == "playback.m4a" and inspect(prepared_audio)["streams"][0]["codec_name"] == "aac", "OGG produces an actual AAC/M4A playback copy")
        video_streams = inspect(prepared_video)["streams"]
        require({stream["codec_type"]: stream["codec_name"] for stream in video_streams} == {"video": "h264", "audio": "aac"}, "AVI produces actual H264 video and AAC audio in MP4")
        require(next(s for s in video_streams if s["codec_type"] == "video")["pix_fmt"] == "yuv420p", "Compatibility video uses broadly decodable 8-bit 4:2:0")
        for path in (prepared_audio, prepared_video):
            decoded = run([ffmpeg, "-nostdin", "-v", "error", "-xerror", "-i", str(path), "-f", "null", "-"], ok=False)
            require(decoded.returncode == 0 and not decoded.stderr.strip(), "Prepared media fully decodes without corrupt samples or video packets")
        for source, directory, metadata in ((ogg, audio_directory, audio), (avi, video_directory, movie)):
            require(metadata["version"] == 1 and metadata["source_path"] == source.relative_to(root).as_posix()
                    and metadata["source_modified_ns"] == source.stat().st_mtime_ns
                    and metadata["source_bytes"] == source.stat().st_size
                    and metadata["bytes"] == (directory / metadata["filename"]).stat().st_size,
                    "Manifest binds output to exact source path, timestamp and byte sizes")
        contents = prepared_video.read_bytes()
        require(contents.index(b"moov") < contents.index(b"mdat"), "MP4 metadata precedes media data for progressive streaming")
        require(all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in originals.items()), "Every original is byte-for-byte unchanged")
        timestamps = (prepared_audio.stat().st_mtime_ns, prepared_video.stat().st_mtime_ns)
        cached = prepare_run()
        require(cached.returncode == 0 and timestamps == (prepared_audio.stat().st_mtime_ns, prepared_video.stat().st_mtime_ns), "Repeated preparation reuses current copies without re-encoding")
        before_manifest = (audio_directory / "manifest.json").read_bytes()
        before_audio = prepared_audio.read_bytes()
        failed = prepare_run("--path", ogg.relative_to(root).as_posix(), "--force", "--ffmpeg", "/usr/bin/false", ok=False)
        require(failed.returncode != 0 and (audio_directory / "manifest.json").read_bytes() == before_manifest
                and prepared_audio.read_bytes() == before_audio, "Failed re-encoding preserves the last complete playback copy")
        require(not list((root / ".miniply-playback").glob(".work-*")), "Failed conversion cleans unfinished staging files")
        if args.keep_fixtures:
            args.keep_fixtures.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(prepared_audio, args.keep_fixtures / "prepared-audio.m4a")
            shutil.copyfile(prepared_video, args.keep_fixtures / "prepared-video.mp4")
            print(f"Playback fixtures: {args.keep_fixtures.resolve()}")

        if args.server_bin:
            with socket.socket() as port_socket:
                port_socket.bind(("127.0.0.1", 0))
                port = port_socket.getsockname()[1]
            token = secrets.token_hex(32)
            environment = {**os.environ, "MINIPLY_MEDIA_ROOT": str(root), "MINIPLY_DATABASE": str(work / "backend.sqlite"),
                           "MINIPLY_TOKEN": token, "MINIPLY_BIND": f"127.0.0.1:{port}", "RUST_LOG": "error"}
            backend = subprocess.Popen([str(args.server_bin.resolve())], env=environment,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            address = f"http://127.0.0.1:{port}"
            def request(path: str, *, method: str = "GET", private: bool = True, byte_range: str | None = None):
                headers = {"Authorization": "Bearer " + token} if private else {}
                if byte_range:
                    headers["Range"] = byte_range
                with urlopen(Request(address + path, headers=headers, method=method), timeout=5) as response:
                    return response.status, response.headers, response.read()
            try:
                for attempt in range(100):
                    try:
                        request("/healthz", private=False)
                        break
                    except OSError:
                        if backend.poll() is not None:
                            raise AssertionError("Local test backend exited before becoming ready")
                        time.sleep(0.05)
                else:
                    raise AssertionError("Local test backend did not become ready")
                page = json.loads(request("/v1/library")[2])
                require(page["total"] == len(originals) and len(page["items"]) == len(originals), "Real API indexes originals once and hides all preparation files")
                by_path = {item["path"]: item for item in page["items"]}
                for source, output, extension in ((ogg, prepared_audio, "m4a"), (avi, prepared_video, "mp4")):
                    item = by_path[source.relative_to(root).as_posix()]
                    require(item["playback"] == {"file_extension": extension, "bytes": output.stat().st_size}
                            and item["bytes"] == source.stat().st_size, "Real API advertises prepared bytes separately from original bytes")
                    ticket = json.loads(request(f'/v1/media/{item["id"]}/ticket', method="POST")[2])
                    status, headers, payload = request(ticket["path"], private=False, byte_range="bytes=0-127")
                    require(status == 206 and headers.get_content_type() == ("audio/mp4" if extension == "m4a" else "video/mp4")
                            and payload == output.read_bytes()[:128], "Signed streaming serves actual prepared bytes with correct Range and MIME")
                    downloaded = request(f'/v1/files/{item["id"]}/download?playback=true')
                    require(downloaded[2] == output.read_bytes() and f".{extension}" in unquote(downloaded[1]["Content-Disposition"]), "App download gets the complete prepared file with matching extension")
                    require(request(f'/v1/files/{item["id"]}/download')[2] == source.read_bytes(), "Original API download still returns the untouched source")
            finally:
                backend.terminate()
                try:
                    backend.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    backend.kill(); backend.wait()

        prepare_run("--path", ogg.relative_to(root).as_posix(), "--audio-codec", "alac")
        require(inspect(prepared_audio)["streams"][0]["codec_name"] == "alac", "Optional ALAC mode produces ALAC/M4A instead of AAC")
        for source in (flac, aiff):
            prepare_run("--path", source.relative_to(root).as_posix(), "--all", "--audio-codec", "alac")
            converted_directory, converted = manifest(source)
            converted_path = converted_directory / converted["filename"]
            def pcm(path: Path):
                return subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "s32le", "-"],
                                      capture_output=True, check=True, timeout=30).stdout
            require(pcm(source) == pcm(converted_path), "ALAC preserves decoded PCM samples of 16/24-bit source audio")
            source_audio = next(stream for stream in inspect(source)["streams"] if stream["codec_type"] == "audio")
            output_audio = next(stream for stream in inspect(converted_path)["streams"] if stream["codec_type"] == "audio")
            require((source_audio["sample_rate"], source_audio["channels"]) == (output_audio["sample_rate"], output_audio["channels"]), "ALAC preserves source sample rate and channel count")
        os.utime(ogg, ns=(ogg.stat().st_atime_ns, ogg.stat().st_mtime_ns + 1_000_000_000))
        prepare_run("--path", ogg.relative_to(root).as_posix())
        require(manifest(ogg)[1]["source_modified_ns"] == ogg.stat().st_mtime_ns, "Changed source timestamp invalidates the previous copy")

        outside = work / "outside.mp3"
        outside.write_bytes(b"not a real MP3; must never be opened")
        link = music / "link.mp3"
        link.symlink_to(outside)
        rejected = prepare_run("--path", "Musik/link.mp3", ok=False)
        require(rejected.returncode != 0 and outside.read_bytes() == b"not a real MP3; must never be opened", "Explicit source symlinks are rejected without following them")
        directory_link = root / "Linked"
        directory_link.symlink_to(work, target_is_directory=True)
        require(prepare_run("--path", "Linked/outside.mp3", ok=False).returncode != 0, "Symlinked source directories are rejected")
        require(prepare_run("--path", "../outside.mp3", ok=False).returncode != 0, "Parent traversal cannot access files outside the selected library")
        fifo = music / "Pipe.mp3"
        os.mkfifo(fifo)
        require(prepare_run("--path", "Musik/Pipe.mp3", ok=False).returncode != 0, "FIFO substitution fails promptly instead of blocking")
        fifo.unlink()
        separate = work / "symlink-cache-library"
        separate.mkdir()
        external_cache = work / "external-cache"
        external_cache.mkdir()
        (separate / ".miniply-playback").symlink_to(external_cache, target_is_directory=True)
        require(prepare_run(ok=False, selected_root=separate).returncode != 0 and not list(external_cache.iterdir()), "Cache-root symlink cannot redirect output outside the library")
        corrupt = music / "Broken.WMA"
        corrupt.write_bytes(b"not media")
        require(prepare_run("--path", "Musik/Broken.WMA", ok=False).returncode != 0, "Corrupt media reports failure without publishing a playable copy")
        require(all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in originals.items()), "Original contents survive all success and failure cases")
    print(f"{checks}/{checks} media preparation regression checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
