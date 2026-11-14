#!/usr/bin/env python3
"""Real ffmpeg check of scripts/prepare-hls.py with generated fixtures."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

script = Path(__file__).resolve().with_name("prepare-hls.py")


def require(condition, message):
    if not condition:
        sys.exit("FAIL " + message)
    print("PASS " + message)


def prepare(root, *arguments):
    return subprocess.run([sys.executable, str(script), str(root), *arguments], capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix="miniply-hls-check-") as folder:
    root = Path(folder)
    (root / "Filme").mkdir()
    source = root / "Filme" / "Probe.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-f", "lavfi",
                    "-i", "sine=frequency=440", "-t", "14", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-shortest", str(source)], check=True)
    small = root / "Filme" / "Klein.webm"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12", "-t", "4",
                    "-c:v", "libvpx", "-b:v", "200k", str(small)], check=True)
    original = hashlib.sha256(source.read_bytes()).hexdigest()

    planned = prepare(root, "--dry-run")
    require(planned.returncode == 0 and "Geschätzter Platzbedarf" in planned.stdout and not (root / ".miniply-hls").exists(),
            "Dry run reports the space and writes nothing")
    speed = prepare(root, "--benchmark", "--path", "Filme/Probe.mp4")
    require(speed.returncode == 0 and "x Echtzeit" in speed.stdout and not (root / ".miniply-hls").exists(),
            "Benchmark reports the speed and leaves no copy")

    done = prepare(root)
    require(done.returncode == 0 and "vorbereitet: Filme/Probe.mp4" in done.stdout, "Both videos are prepared: " + done.stderr[-300:])
    require(hashlib.sha256(source.read_bytes()).hexdigest() == original, "The original stays unchanged")
    copy = root / ".miniply-hls" / hashlib.sha256(b"Filme/Probe.mp4").hexdigest()
    master = (copy / "master.m3u8").read_text()
    manifest = json.loads((copy / "manifest.json").read_text())
    require(manifest["source_path"] == "Filme/Probe.mp4" and manifest["source_bytes"] == source.stat().st_size
            and manifest["source_modified_ns"] == source.stat().st_mtime_ns, "The manifest describes the exact source")
    variants = re.findall(r"BANDWIDTH=(\d+),AVERAGE-BANDWIDTH=\d+,RESOLUTION=(\d+)x(\d+),CODECS=\"([^\"]+)\"\n(v\d+/index\.m3u8)", master)
    require(len(variants) == 2 and {int(v[2]) for v in variants} == {720, 480}, "Original and 480p are offered")
    require([int(v[0]) for v in variants] == sorted(int(v[0]) for v in variants), "Steps are sorted by bandwidth")
    require(all(v[3].startswith("avc1.") and "mp4a.40.2" in v[3] for v in variants), "Codecs are declared")
    for variant in variants:
        playlist = (copy / variant[4]).read_text()
        segments = re.findall(r"seg\d+\.ts", playlist)
        require("#EXT-X-ENDLIST" in playlist and segments and all((copy / Path(variant[4]).parent / s).stat().st_size > 0 for s in segments),
                f"{variant[4]} is complete")
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", "-allowed_extensions", "ALL",
                            str(copy / "master.m3u8")], capture_output=True, text=True)
    require(abs(float(probe.stdout.strip() or 0) - 14) < 1.5, "The copy is as long as the source")
    webm = root / ".miniply-hls" / hashlib.sha256(b"Filme/Klein.webm").hexdigest() / "master.m3u8"
    require(webm.exists() and "RESOLUTION=320x180" in webm.read_text() and webm.read_text().count("EXT-X-STREAM-INF") == 1,
            "A small video that needs converting gets one step without upscaling")
    require(not list((root / ".miniply-hls").glob(".work-*")), "No work folder stays behind")

    # A picture stored sideways, as iPhones do for portrait videos.
    turned = root / "Filme" / "Hochkant.mp4"
    plain = Path(folder) / "plain.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-t", "7", "-c:v", "libx264",
                    "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(plain)], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-display_rotation", "90", "-i", str(plain), "-c", "copy", str(turned)], check=True)
    plain.unlink()
    rotated = prepare(root, "--path", "Filme/Hochkant.mp4")
    require(rotated.returncode == 0, "A rotated video is prepared: " + rotated.stderr[-300:])
    upright = root / ".miniply-hls" / hashlib.sha256(b"Filme/Hochkant.mp4").hexdigest()
    sizes = re.findall(r"RESOLUTION=(\d+)x(\d+)", (upright / "master.m3u8").read_text())
    require(sizes and all(int(height) > int(width) for width, height in sizes), f"A rotated video is offered upright: {sizes}")
    require(len(sizes) == 2, "A rotated video is converted in all its steps instead of reused")
    for index, (width, height) in enumerate(sorted(sizes, key=lambda size: int(size[1]), reverse=True)):
        actual = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height", "-of", "csv=p=0"]
                                + [str(next(upright.glob(f"v{index}/seg*.ts")))], capture_output=True, text=True).stdout.split()
        require(actual and actual[0] == f"{width},{height}", f"The picture of step {index} really is {width}x{height}")
    left = root / ".miniply-hls" / ".work-alt"
    left.mkdir()
    (left / "rest.ts").write_bytes(b"x")
    prepare(root, "--path", "Filme/Hochkant.mp4")
    require(not left.exists(), "A later run removes what an ended run left behind")
    worker = subprocess.Popen([sys.executable, str(script), str(root), "--force", "--path", "Filme/Probe.mp4"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(500):
        if list((root / ".miniply-hls").glob(".work-*")):
            break
        time.sleep(0.01)
    started = bool(list((root / ".miniply-hls").glob(".work-*")))
    worker.terminate()
    worker.wait(timeout=20)
    require(started and not list((root / ".miniply-hls").glob(".work-*")), "Stopping the service leaves no work folder")

    again = prepare(root)
    require("vorhanden: Filme/Probe.mp4" in again.stdout, "A current copy is not converted again")
    os.utime(source, ns=(source.stat().st_atime_ns, source.stat().st_mtime_ns + 1))
    changed = prepare(root, "--path", "Filme/Probe.mp4")
    require("vorbereitet: Filme/Probe.mp4" in changed.stdout and not list((root / ".miniply-hls").glob(".old-*")),
            "A changed source replaces its copy cleanly")
    (root / "Filme" / "Kaputt.mp4").write_bytes(b"keine Videodatei")
    broken = prepare(root, "--path", "Filme/Kaputt.mp4")
    require(broken.returncode == 1 and not (root / ".miniply-hls" / hashlib.sha256(b"Filme/Kaputt.mp4").hexdigest()).exists(),
            "A damaged file reports an error and publishes nothing")
print("HLS preparation checks passed")
