#!/usr/bin/env python3
"""Create a quiet, original WAV sample and a document, with no downloads."""
from pathlib import Path
import math
import struct
import wave

root = Path(__file__).resolve().parents[1] / "media"
music = root / "Musik/Mediaserver/Erste Schritte"
music.mkdir(parents=True, exist_ok=True)
path = music / "Willkommen.wav"
if not path.exists():
    with wave.open(str(path), "wb") as wav:
        wav.setparams((1, 2, 22050, 0, "NONE", "not compressed"))
        wav.writeframes(b"".join(struct.pack("<h", int(300 * math.sin(2 * math.pi * 220 * n / 22050))) for n in range(22050 * 30)))
    def chunk(key, value):
        data = value.encode() + b"\0"
        return key + struct.pack("<I", len(data)) + data + b"\0" * (len(data) % 2)
    tags = b"INFO" + chunk(b"INAM", "Willkommen") + chunk(b"IART", "Mediaserver") + chunk(b"IPRD", "Erste Schritte")
    data = path.read_bytes() + b"LIST" + struct.pack("<I", len(tags)) + tags
    path.write_bytes(data[:4] + struct.pack("<I", len(data) - 8) + data[8:])
docs = root / "Dokumente"
docs.mkdir(exist_ok=True)
document = docs / "Lies mich.txt"
if not document.exists():
    document.write_text("Willkommen bei Mediaserver. Diese Datei testet den geschützten Download.\n")
print(f"Demo-Dateien: {root}")
