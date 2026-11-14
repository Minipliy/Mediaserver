#!/usr/bin/env python3
"""Prüft scripts/folgen-hochladen.py mit kurzen Videos und Ersatz für Whisper, ssh und rsync."""
import importlib.util
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

skript = Path(__file__).with_name("folgen-hochladen.py")
spec = importlib.util.spec_from_file_location("folgen", skript)
folgen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(folgen)

roh = "1\n00:00:01,000 --> 00:00:02,500\nHello\nthere\n\n2\n00:00:03,000 --> 00:00:04,000\n[Music]\n\n3\n00:00:05,000 --> 00:00:06,000\n(door closes)\n\n"
assert folgen.zeilen_aus_srt(roh) == [(1000, 2500, "Hello there")]
assert folgen.als_srt([(301000, 302500, "Hi")]) == "1\n00:05:01,000 --> 00:05:02,500\nHi\n\n"
for name, erwartet in {
    "Two and a Half Men S01E02 Big Flappy Bastards.mp4": "Serien/Two and a Half Men/Season 1",
    "Two.and.a.Half.Men.s10e05.1080p.WEB.mkv": "Serien/Two and a Half Men/Season 10",
    "Show - 3x07 - Titel.mkv": "Serien/Show/Season 3",
    "Ein Film (2010).mp4": "Filme",
}.items():
    assert folgen.zielordner(Path(name)) == erwartet, name
assert folgen.folgennummer("Show.s02e05.mkv") == (2, 5) and folgen.folgennummer("Show 3x07.mp4") == (3, 7)
assert folgen.folgennummer("Film.mp4") is None
assert folgen.zielordner(Path("/x/Meine Show/Staffel 2/S02E01.mp4")) == "Serien/Meine Show/Season 2"
for falsch in ("/mnt/media/Serien", "Serien/../..", "Musik/x", ""):
    try:
        folgen.ziel_pruefen(falsch)
    except folgen.Abbruch:
        continue
    raise AssertionError(falsch)

if shutil.which("ffmpeg") is None:
    print("Untertitel: ffmpeg fehlt, nur die Textprüfung lief.")
    sys.exit(0)

WHISPER = r"""#!/usr/bin/env python3
import os, sys
a = sys.argv
if "-dl" in a:
    print("auto-detected language: en", file=sys.stderr)
    sys.exit(0)
with open(os.environ["PROTOKOLL"], "a") as f:
    print(a[a.index("-l") + 1], file=f)
if os.environ.get("WHISPER_STUMM"):
    open(a[a.index("-of") + 1] + ".srt", "w").close()
    sys.exit(0)
with open(a[a.index("-of") + 1] + ".srt", "w") as f:
    f.write("1\n00:00:01,000 --> 00:00:02,000\nHallo\n\n")
"""
SSH = '#!/bin/sh\n[ -z "$SSH_KAPUTT" ] || exit 255\nshift\nexec sh -c "$1"\n'
RSYNC = '''#!/bin/sh
[ -n "$RSYNC_KAPUTT" ] && case "$2" in *.mp4) exit 12;; esac
ziel=${3#*:}
eval "cp \\"\\$2\\" $ziel"
'''


def ausfuehrbar(pfad, inhalt):
    pfad.write_text(inhalt)
    pfad.chmod(pfad.stat().st_mode | stat.S_IEXEC)


with tempfile.TemporaryDirectory() as ordner:
    basis = Path(ordner)
    werkzeuge, mac, pi = basis / "bin", basis / "mac folgen", basis / "pi"
    werkzeuge.mkdir()
    mac.mkdir()
    (pi / "Serien" / "Show").mkdir(parents=True)
    ausfuehrbar(werkzeuge / "whisper-cli", WHISPER)
    ausfuehrbar(werkzeuge / "ssh", SSH)
    ausfuehrbar(werkzeuge / "rsync", RSYNC)
    modell = basis / "modell.bin"
    modell.write_text("m")
    protokoll = basis / "protokoll"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "2",
                    str(mac / "show S01E01 Pilot's Teil.mp4")], check=True)
    umgebung = dict(os.environ, PATH=f"{werkzeuge}:{os.environ['PATH']}", PROTOKOLL=str(protokoll))
    aufruf = [sys.executable, str(skript), str(mac), "--modell", str(modell), "--server", "pi", "--wurzel", str(pi)]

    def lauf(*mehr, **umg):
        return subprocess.run(aufruf + list(mehr), env={**umgebung, **umg}, capture_output=True, text=True)

    def aufrufe():
        return protokoll.read_text().split() if protokoll.exists() else []

    # Nur zeigen: nichts entsteht, und die Serie wird wie auf dem Pi geschrieben.
    ergebnis = lauf("-n")
    assert ergebnis.returncode == 0 and "nach Serien/Show/Season 1/" in ergebnis.stdout, ergebnis
    assert not (pi / "Serien/Show/Season 1").exists() and not aufrufe()

    # Abbruch beim Video-Upload: Der Untertitel bleibt und wird nicht neu erstellt.
    ergebnis = lauf(RSYNC_KAPUTT="1")
    assert ergebnis.returncode == 1 and "nicht geschafft" in ergebnis.stderr, ergebnis
    staffel = pi / "Serien/Show/Season 1"
    assert (staffel / "show S01E01 Pilot's Teil.en.srt").exists() and not (staffel / "show S01E01 Pilot's Teil.mp4").exists()

    ergebnis = lauf()
    assert ergebnis.returncode == 0, ergebnis
    assert (staffel / "show S01E01 Pilot's Teil.mp4").exists()
    assert (mac / "show S01E01 Pilot's Teil.en.srt").read_text() == "1\n00:00:01,000 --> 00:00:02,000\nHallo\n\n"
    assert aufrufe() == ["en"], aufrufe()

    # Alles da: Es wird nichts erstellt und nichts überschrieben.
    (staffel / "show S01E01 Pilot's Teil.en.srt").write_text("vom Pi")
    (mac / "show S01E01 Pilot's Teil.en.srt").unlink()
    ergebnis = lauf()
    assert ergebnis.returncode == 0 and "schon komplett" in ergebnis.stdout, ergebnis
    assert (staffel / "show S01E01 Pilot's Teil.en.srt").read_text() == "vom Pi" and aufrufe() == ["en"]

    # Ohne Sprache: Das Video kommt trotzdem hoch, die feste Sprache gilt, keine Reste bleiben.
    shutil.copy(mac / "show S01E01 Pilot's Teil.mp4", mac / "Film ohne Worte.mp4")
    ergebnis = lauf("--sprache", "de", WHISPER_STUMM="1")
    assert ergebnis.returncode == 0, ergebnis
    assert (pi / "Filme/Film ohne Worte.mp4").exists() and not list((pi / "Filme").glob("*.srt"))
    assert aufrufe() == ["en", "de"], aufrufe()
    assert not list(mac.glob(".*")), "Zwischendateien sind liegen geblieben"

    # Dieselbe Folge unter anderem Namen wird nicht doppelt hochgeladen und nicht erst bearbeitet.
    anders = basis / "anders"
    anders.mkdir()
    shutil.copy(mac / "Film ohne Worte.mp4", anders / "Show.S01E01.1080p.mp4")
    ergebnis = subprocess.run([sys.executable, str(skript), str(anders), "--modell", str(modell), "--server", "pi", "--wurzel", str(pi)],
                              env=umgebung, capture_output=True, text=True)
    assert ergebnis.returncode == 1 and "schon als" in ergebnis.stderr, ergebnis
    assert not (staffel / "Show.S01E01.1080p.mp4").exists() and aufrufe() == ["en", "de"], aufrufe()

    # Nur Untertitel: Es geht ohne Pi, und der spätere Upload nimmt die fertige Datei mit.
    spaeter = basis / "spaeter"
    spaeter.mkdir()
    shutil.copy(mac / "Film ohne Worte.mp4", spaeter / "Show S02E01 Neu.mp4")
    aufruf[2] = str(spaeter)
    srt = spaeter / "Show S02E01 Neu.en.srt"
    ergebnis = lauf("--nur-untertitel", "-n", SSH_KAPUTT="1")
    assert ergebnis.returncode == 0 and "bekommt Untertitel" in ergebnis.stdout and not srt.exists(), ergebnis
    ergebnis = lauf("--nur-untertitel", SSH_KAPUTT="1")
    assert ergebnis.returncode == 0 and srt.exists() and "Hochgeladen ist noch nichts" in ergebnis.stdout, ergebnis
    assert not (pi / "Serien/Show/Season 2").exists() and aufrufe() == ["en", "de", "en"], aufrufe()
    ergebnis = lauf("--nur-untertitel", SSH_KAPUTT="1")
    assert ergebnis.returncode == 0 and "hat schon" in ergebnis.stdout and aufrufe() == ["en", "de", "en"], ergebnis
    ergebnis = lauf()
    assert ergebnis.returncode == 0 and aufrufe() == ["en", "de", "en"], ergebnis
    assert (pi / "Serien/Show/Season 2/Show S02E01 Neu.mp4").exists() and (pi / "Serien/Show/Season 2" / srt.name).exists()
    aufruf[2] = str(mac)

    # Falsche Eingaben enden mit einer klaren Meldung.
    ergebnis = lauf("--ziel", "/etc")
    assert ergebnis.returncode == 1 and "--ziel" in ergebnis.stderr, ergebnis
print("Untertitel: alle Prüfungen bestanden.")
