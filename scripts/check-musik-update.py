#!/usr/bin/env python3
"""Prüft das Selbst-Update: zweiter Versuch im Musik-Dienst und das Update-Skript mit Ersatzprogrammen."""
import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import threading
import time
import zipfile
from pathlib import Path

wurzel = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("musik", wurzel / "scripts/musik-suchen.py")
musik = importlib.util.module_from_spec(spec)
spec.loader.exec_module(musik)


def plan(_item=None):
    return {"artist": "Ada", "album": "Eins", "source": "test", "cover": None,
            "titles": [{"title": "Lied", "seconds": 100}]}


musik.lookup = lambda _item: {"trackNumber": 1}
musik.song_plan = plan
musik.save_cover = lambda _cover, _folder: None
musik.UPDATE_POLL_SECONDS = 0.01
musik.MIN_FREE_BYTES = 0  # Der freie Platz auf dem Prüfrechner gehört nicht zu diesem Test.


def auftrag(ordner, nummer, updater, tools_neu, laden):
    """Führt einen Auftrag aus. `updater` spielt den Systemdienst, der die Bitte abarbeitet."""
    jobs, ziel = ordner / "jobs", ordner / "ziel"
    jobs.mkdir(exist_ok=True)
    ziel.mkdir(exist_ok=True)
    einheit = ordner / "einheit"
    if updater:
        einheit.touch()
    musik.UPDATE_UNIT = str(einheit if updater else ordner / "fehlt")
    stand = {"wert": 1}
    musik.tools_stamp = lambda: [stand["wert"]]
    versuche = []
    musik.find_on_youtube = lambda *_: [{"id": "x"}]

    def lade(_video, folder, number, _plan, _position, censored=False):
        versuche.append(number)
        if not laden(len(versuche)):
            return False
        Path(folder, "01 Lied.m4a").write_bytes(b"ton")
        return True

    musik.download_song = lade
    flag = jobs / "update-wanted"
    ende = threading.Event()

    def dienst():
        while not ende.wait(0.01):
            if flag.exists():
                if tools_neu:
                    stand["wert"] += 1
                flag.unlink()

    faden = threading.Thread(target=dienst)
    if updater:
        faden.start()
    try:
        job_id = f"job{nummer}"
        musik.run_job({"id": job_id, "item_id": 1, "kind": "song"}, str(jobs), str(ziel))
    finally:
        ende.set()
        if updater:
            faden.join()
    assert not flag.exists(), "Die Bitte um ein Update bleibt nicht liegen"
    return json.loads((jobs / f"{job_id}.state.json").read_text()), len(versuche), ziel


with tempfile.TemporaryDirectory() as tmp:
    ordner = Path(tmp)
    # Neues yt-dlp behebt es: zweiter Versuch lädt den Song.
    ergebnis, versuche, ziel = auftrag(ordner, 1, True, True, lambda n: n > 1)
    assert ergebnis["state"] == "done" and versuche == 2, ergebnis
    assert (ziel / "Ada - Eins" / "01 Lied.m4a").exists()
    # Kein neues yt-dlp: kein sinnloser zweiter Versuch.
    (ziel / "Ada - Eins" / "01 Lied.m4a").unlink()
    ergebnis, versuche, _ = auftrag(ordner, 2, True, False, lambda _: False)
    assert ergebnis["state"] == "failed" and versuche == 1 and "Treffer" in ergebnis["message"], ergebnis
    # Neues yt-dlp hilft auch nicht: genau ein zweiter Versuch, keine Schleife.
    ergebnis, versuche, _ = auftrag(ordner, 3, True, True, lambda _: False)
    assert ergebnis["state"] == "failed" and versuche == 2 and "nach dem Update" in ergebnis["message"], ergebnis
    # Update-Einheit noch nicht eingerichtet: Es wird nicht zehn Minuten gewartet.
    start = time.monotonic()
    ergebnis, versuche, _ = auftrag(ordner, 4, False, False, lambda _: False)
    assert ergebnis["state"] == "failed" and versuche == 1 and time.monotonic() - start < 5, ergebnis


def ausfuehrbar(pfad, inhalt):
    pfad.write_text(inhalt)
    pfad.chmod(pfad.stat().st_mode | stat.S_IXUSR)


def update_lauf(ordner, werkzeuge, yt_inhalt, version_ok=True):
    """Startet das Update-Skript mit Ersatz für curl und setpriv. Antwortet mit Exit-Code und Abrufen."""
    netz, stubs = ordner / "netz", ordner / "stubs"
    netz.mkdir(exist_ok=True)
    stubs.mkdir(exist_ok=True)
    (netz / "yt-dlp_linux_aarch64").write_text(yt_inhalt)
    summe = hashlib.sha256(yt_inhalt.encode()).hexdigest()
    (netz / "SHA2-256SUMS").write_text(f"{summe}  yt-dlp_linux_aarch64\n{'0' * 64}  anderes\n")
    zip_name = "deno-aarch64-unknown-linux-gnu.zip"
    if not (netz / zip_name).exists():
        with zipfile.ZipFile(netz / zip_name, "w") as archiv:
            archiv.writestr("deno", "#!/bin/sh\nexit 0\n")
        subprocess.run(f'cd "{netz}" && sha256sum {zip_name} > {zip_name}.sha256sum', shell=True, check=True)
    protokoll = ordner / "abrufe"
    protokoll.write_text("")
    ausfuehrbar(stubs / "curl", f'#!/bin/sh\nfor a; do u=$a; done\nn=${{u##*/}}\necho "$n" >> "{protokoll}"\ncp "{netz}/$n" .\n')
    ausfuehrbar(stubs / "setpriv", '#!/bin/sh\nwhile [ "$1" != env ]; do shift; done\nshift\nexec env "$@"\n')
    umgebung = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", MUSIK_WERKZEUGE=str(werkzeuge))
    lauf = subprocess.run(["sh", str(wurzel / "deploy/musik-werkzeuge-aktualisieren.sh")], env=umgebung,
                          capture_output=True, text=True, cwd=ordner)
    return lauf.returncode, protokoll.read_text().split(), lauf.stdout + lauf.stderr


with tempfile.TemporaryDirectory() as tmp:
    ordner = Path(tmp)
    werkzeuge = ordner / "tools"
    gut = "#!/bin/sh\necho 1\n"
    code, abrufe, text = update_lauf(ordner, werkzeuge, gut)
    assert code == 0, text
    assert (werkzeuge / "yt-dlp").read_text() == gut and (werkzeuge / "deno").exists(), text
    assert "yt-dlp_linux_aarch64" in abrufe
    # Nichts Neues: Es werden nur die kleinen Prüfsummen geholt.
    code, abrufe, text = update_lauf(ordner, werkzeuge, gut)
    assert code == 0 and sorted(abrufe) == ["SHA2-256SUMS", "deno-aarch64-unknown-linux-gnu.zip.sha256sum"], (abrufe, text)
    # Neue Version startet nicht: Die alte bleibt.
    code, _, text = update_lauf(ordner, werkzeuge, "#!/bin/sh\nexit 3\n")
    assert code != 0 and (werkzeuge / "yt-dlp").read_text() == gut, text
    # Neue Version startet: Sie ersetzt die alte.
    neu = "#!/bin/sh\necho 2\n"
    code, _, text = update_lauf(ordner, werkzeuge, neu)
    assert code == 0 and (werkzeuge / "yt-dlp").read_text() == neu, text
    assert not (werkzeuge / "yt-dlp.neu").exists()

def ton(pfad, bitrate, **tags):
    metadaten = [a for name, wert in tags.items() for a in ("-metadata", f"{name}={wert}")]
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "anoisesrc=duration=5:amplitude=0.3",
                    "-c:a", "aac", "-b:a", bitrate, *metadaten, str(pfad)], check=True)


with tempfile.TemporaryDirectory() as tmp:
    # Neu laden: gleicher Name, alte Tags, alte Datei im Papierkorb, kein zweiter Durchgang.
    mediathek = Path(tmp) / "media"
    album = mediathek / "Musik" / "Ada - Eins"
    album.mkdir(parents=True)
    song, ohne = album / "01 Lied.m4a", album / "02 Anders.m4a"
    ton(song, "96k", title="Lied (feat. Bo)", artist="Ada", album_artist="Ada", album="Eins", track="1/2")
    ton(ohne, "96k", title="Anders", artist="Ada", album="Eins")
    musik.REPLACE_STATE = str(Path(tmp) / "stand.json")
    musik.catalog_song = lambda _a, title, _b: {"trackTimeMillis": 5000, "trackExplicitness": "explicit"}
    musik.find_on_youtube = lambda _a, title, *_: [{"id": "x"}] if title.startswith("Lied") else []
    geladen = []

    def lade_ton(_video, work, seconds, _title):
        geladen.append(seconds)
        ziel = Path(work, "ton.m4a")
        ton(ziel, "256k")
        return str(ziel)

    musik.download_audio = lade_ton
    musik.replace_all([str(mediathek / "Musik")], str(mediathek), True)
    assert not geladen, "Der Testlauf lädt nichts"
    musik.replace_all([str(mediathek / "Musik")], str(mediathek), False)
    tags, _, bitrate = musik.file_tags(str(song))
    assert geladen == [5] and bitrate > 200_000 and tags.get("title") == "Lied (feat. Bo)", (tags, bitrate)
    alt = list(mediathek.glob(".miniply-papierkorb/*/Musik/Ada - Eins/01 Lied.m4a"))
    assert len(alt) == 1 and musik.file_tags(str(alt[0]))[2] < 200_000, alt
    assert musik.file_tags(str(ohne))[2] < 200_000, "Ohne unzensierte Quelle bleibt der alte Song"
    assert not list(album.glob(".lade-*")), "Zwischenordner bleiben nicht liegen"
    stand = json.loads(Path(musik.REPLACE_STATE).read_text())
    assert stand["Musik/Ada - Eins/01 Lied.m4a"] == "neu geladen" and "unzensiert" in stand["Musik/Ada - Eins/02 Anders.m4a"]
    musik.replace_all([str(mediathek / "Musik")], str(mediathek), False)
    assert geladen == [5], "Ein zweiter Lauf lädt nichts doppelt"

# Song-Auswahl: unzensiert zuerst, höchstens 5 Sekunden daneben, sonst eine andere Fassung.
auswahl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auswahl)
treffer = {
    "Ada Lied": [{"id": "sauber", "title": "Lied", "artist": "Ada", "album": "Eins", "duration": 200, "explicit": False},
                 {"id": "zu-lang", "title": "Lied", "artist": "Ada", "album": "Eins", "duration": 206, "explicit": True}],
    "Lied Ada explicit": [{"id": "unzensiert", "title": "Lied", "artist": "Ada", "album": "Eins", "duration": 204,
                           "explicit": True}],
}
anfragen = []
auswahl.music_search = lambda query: anfragen.append(query) or treffer.get(query, [])
auswahl.video_fallback = lambda *_: [{"id": "video"}]
ids = lambda quellen: [q["id"] for q in quellen]
assert ids(auswahl.find_on_youtube("Ada", "Lied", 200, "Eins", True)) == ["unzensiert"], anfragen
assert "Lied Ada explicit" in anfragen, "Für unzensiert wird gründlicher gesucht"
del treffer["Lied Ada explicit"]
assert ids(auswahl.find_on_youtube("Ada", "Lied", 200, "Eins", True)) == ["sauber"], "Ohne Unzensiertes die andere Fassung"
assert auswahl.find_on_youtube("Ada", "Lied", 200, "Eins", True, False) == [], "Beim Ersetzen keine zensierte"
assert ids(auswahl.find_on_youtube("Ada", "Nichts", 200, "Eins", False)) == ["video"]
assert auswahl.key("André 3000") == auswahl.key("Andre\u0301 3000") == auswahl.key("Andre 3000")
assert auswahl.merge_guests("Drake", ["André 3000"], ["Lil Wayne", "Andre 3000"]) == ["André 3000", "Lil Wayne"]

print("Musik-Update ist in Ordnung")
