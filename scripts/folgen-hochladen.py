#!/usr/bin/env python3
"""Erstellt auf dem Mac Untertitel für Folgen und Filme und lädt beides auf den Pi.

    scripts/folgen-hochladen.py "/Pfad/zum/Ordner" "/Pfad/zur/Folge.mkv"
    scripts/folgen-hochladen.py -n "/Pfad/zum/Ordner"      zeigt nur, was passieren würde
    scripts/folgen-hochladen.py --sprache en "/Pfad"       Sprache festlegen statt erkennen
    scripts/folgen-hochladen.py --ziel "Serien/Show/Season 1" "/Pfad"    Ordner auf dem Pi festlegen
    scripts/folgen-hochladen.py --nur-untertitel "/Pfad"   erstellt nur Untertitel, ohne den Pi; ein
                                                           späterer Lauf ohne die Option lädt alles hoch

Das Ziel kommt aus dem Dateinamen: "Show S01E02 ..." landet in Serien/Show/Season 1,
alles andere in Filme. Die Datei "Folge.en.srt" bleibt neben dem Video auf dem Mac, ein
abgebrochener Lauf macht also dort weiter. Auf dem Pi wird nichts überschrieben.
Braucht whisper.cpp: brew install whisper-cpp
"""
import argparse
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

VIDEO_ENDINGEN = {".mp4", ".m4v", ".mov", ".mkv", ".avi", ".webm"}
UNTERTITEL_ENDINGEN = {".srt", ".vtt"}
MODELLE = {
    "base": "465707469ff3a37a2b9b8d8f89f2f99de7299dac",
    "small": "55356645c2b361a969dfd0ef2c5a50d530afd8d5",
    "medium": "fd9727b6e1217c2f614f9b698455c4ffd82463b4",
}
MODELL_ORDNER = Path.home() / "Library/Caches/miniply/whisper"
MODELL_QUELLE = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{}.bin"
ZEILE_ZEICHEN = 60
# Vorspann und Lacher täuschen die Erkennung, darum zählt ein Stück aus der Mitte.
SPRACHPROBE_SEKUNDEN = 60

FOLGE = re.compile(r"^(?P<show>.*?)[ ._-]*(?:s(?P<staffel>\d{1,2})[ ._-]*e(?P<folge>\d{1,3})|(?P<staffel2>\d{1,2})x(?P<folge2>\d{2,3}))(?!\d)", re.I)
ZEIT = r"(\d+):(\d\d):(\d\d)[,.](\d{3})"
BLOCK = re.compile(ZEIT + r"\s*-->\s*" + ZEIT + r"[^\n]*\n(.*?)(?:\n\s*\n|\Z)", re.S)
NUR_GERAEUSCH = re.compile(r"^[\[(♪*][^\])]*[\])♪*]?$")


class Abbruch(Exception):
    pass


def natuerlich(pfad):
    return [int(teil) if teil.isdigit() else teil.lower() for teil in re.split(r"(\d+)", str(pfad))]


def millisekunden(stunde, minute, sekunde, milli):
    return (int(stunde) * 3600 + int(minute) * 60 + int(sekunde)) * 1000 + int(milli)


def zeitstempel(ms):
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def zeilen_aus_srt(text):
    """(Beginn, Ende, Text) in ms; Einträge nur aus Geräuschen wie "[Music]" entfallen."""
    ergebnis = []
    for treffer in BLOCK.finditer(text.replace("\r\n", "\n") + "\n\n"):
        gruppen = treffer.groups()
        inhalt = " ".join(zeile.strip() for zeile in gruppen[8].splitlines() if zeile.strip())
        if inhalt and not NUR_GERAEUSCH.match(inhalt):
            ergebnis.append((millisekunden(*gruppen[:4]), millisekunden(*gruppen[4:8]), inhalt))
    return ergebnis


def als_srt(zeilen):
    return "".join(f"{nummer}\n{zeitstempel(beginn)} --> {zeitstempel(ende)}\n{text}\n\n"
                   for nummer, (beginn, ende, text) in enumerate(zeilen, 1))


def videos_finden(eingaben):
    gefunden = []
    for eingabe in eingaben:
        if eingabe.is_file():
            if eingabe.suffix.lower() not in VIDEO_ENDINGEN:
                raise Abbruch(f"Kein Video: {eingabe}")
            gefunden.append(eingabe)
        elif eingabe.is_dir():
            for basis, ordner, dateien in os.walk(eingabe):
                ordner[:] = [name for name in ordner if not name.startswith(".")]
                gefunden += [Path(basis, name) for name in dateien
                             if not name.startswith(".") and Path(name).suffix.lower() in VIDEO_ENDINGEN]
        else:
            raise Abbruch(f"Nicht gefunden: {eingabe}")
    return sorted(set(gefunden), key=natuerlich)


def lesbar(name):
    return re.sub(r"\s+", " ", name.replace(".", " ").replace("_", " ")).strip(" -")


def zielordner(video):
    """Ordner relativ zur Mediathek: Serien/Show/Season 1 oder Filme."""
    treffer = FOLGE.match(video.stem)
    if not treffer:
        return "Filme"
    staffel = int(treffer["staffel"] or treffer["staffel2"])
    show = lesbar(treffer["show"])
    if not show:
        eltern = video.resolve().parent
        if re.fullmatch(r"(season|staffel)[ ._-]*\d+", eltern.name, re.I):
            eltern = eltern.parent
        show = lesbar(eltern.name)
    if not show:
        raise Abbruch(f"Kein Serienname erkennbar, bitte --ziel angeben: {video.name}")
    return f"Serien/{show}/Season {staffel}"


def folgennummer(name):
    """(Staffel, Folge) aus einem Dateinamen, sonst None."""
    treffer = FOLGE.match(Path(name).stem)
    if not treffer:
        return None
    return int(treffer["staffel"] or treffer["staffel2"]), int(treffer["folge"] or treffer["folge2"])


def ziel_pruefen(ziel):
    teile = Path(ziel).parts
    if not teile or Path(ziel).is_absolute() or ".." in teile or teile[0] not in ("Serien", "Filme"):
        raise Abbruch('--ziel muss in Serien/ oder Filme/ liegen, zum Beispiel "Serien/Show/Season 1".')
    return ziel


def untertitel_von(video):
    praefix = video.stem.lower() + "."
    return [datei for datei in video.parent.iterdir()
            if datei.suffix.lower() in UNTERTITEL_ENDINGEN and datei.name.lower().startswith(praefix)]


class Pi:
    """Mediathek auf dem Pi, erreicht über ssh. Liest nur Ordner und legt neue Dateien an."""

    def __init__(self, server, wurzel):
        self.server, self.wurzel = server, wurzel.rstrip("/")
        self.listen = {}

    def ssh(self, befehl):
        antwort = subprocess.run(["ssh", self.server, befehl], capture_output=True, text=True)
        if antwort.returncode == 255:
            raise Abbruch(f"Der Pi ist nicht erreichbar: {antwort.stderr.strip()}")
        return antwort

    def namen(self, ordner):
        if ordner not in self.listen:
            antwort = self.ssh(f"ls -A {shlex.quote(self.wurzel + '/' + ordner)} 2>/dev/null")
            self.listen[ordner] = set(antwort.stdout.splitlines())
        return self.listen[ordner]

    def bekannte_schreibweise(self, ordner):
        """Gibt es die Serie schon anders geschrieben, kommt die Folge zu ihr statt in einen zweiten Ordner."""
        if not ordner.startswith("Serien/"):
            return ordner
        teile = ordner.split("/")
        for vorhanden in self.namen("Serien"):
            if vorhanden.lower() == teile[1].lower():
                teile[1] = vorhanden
        return "/".join(teile)

    def hochladen(self, datei, ordner):
        pfad = f"{self.wurzel}/{ordner}"
        antwort = self.ssh(f"mkdir -p {shlex.quote(pfad)}")
        if antwort.returncode != 0:
            raise RuntimeError(f"Ordner auf dem Pi nicht angelegt: {antwort.stderr.strip()}")
        # rsync schreibt in eine versteckte Datei und benennt sie erst am Ende um,
        # der Server sieht also nie eine halbe Folge.
        ziel = f"{self.server}:{shlex.quote(pfad + '/' + datei.name)}"
        subprocess.run(["rsync", "-t", str(datei), ziel], check=True)
        self.listen.setdefault(ordner, set()).add(datei.name)


def modell_holen(name):
    pfad = MODELL_ORDNER / f"ggml-{name}.bin"
    if pfad.exists():
        return pfad
    print(f"Lade das Sprachmodell {name} (nur beim ersten Mal) …", flush=True)
    MODELL_ORDNER.mkdir(parents=True, exist_ok=True)
    zwischen = pfad.with_suffix(".teil")
    # curl statt urllib: Das Python von python.org kennt ohne Zusatzschritt keine Zertifikate.
    if subprocess.run(["curl", "-fL", "-C", "-", "--progress-bar", "-o", str(zwischen), MODELL_QUELLE.format(name)]).returncode != 0:
        raise Abbruch("Das Sprachmodell konnte nicht geladen werden. Ein neuer Lauf macht dort weiter.")
    summe = hashlib.sha1()
    with zwischen.open("rb") as datei:
        while stueck := datei.read(1024 * 1024):
            summe.update(stueck)
    if summe.hexdigest() != MODELLE[name]:
        zwischen.unlink()
        raise Abbruch("Das geladene Sprachmodell hat die falsche Prüfsumme.")
    os.replace(zwischen, pfad)
    return pfad


def sprache_erkennen(ton, gesamt, whisper, modell, ordner):
    probe = Path(ordner, "probe.wav")
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", str(max(0, gesamt / 2)), "-t", str(SPRACHPROBE_SEKUNDEN),
                    "-i", str(ton), "-c", "copy", str(probe)], check=True)
    antwort = subprocess.run([whisper, "-m", str(modell), "-f", str(probe), "-l", "auto", "-dl"],
                             capture_output=True, text=True, errors="replace")
    erkannt = re.search(r"auto-detected language: (\w+)", antwort.stderr + antwort.stdout)
    return erkannt.group(1) if erkannt else None


def untertitel_erstellen(video, optionen, modell):
    """Schreibt Video.<Sprache>.srt neben das Video. None, wenn nichts gesprochen wird."""
    with tempfile.TemporaryDirectory() as ordner:
        ton = Path(ordner, "ton.wav")
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(video), "-vn", "-ac", "1", "-ar", "16000",
                        "-f", "wav", str(ton)], check=True)
        gesamt = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(ton)],
                                      capture_output=True, text=True, check=True).stdout.strip())
        sprache = optionen.sprache or sprache_erkennen(ton, gesamt, optionen.whisper, modell, ordner)
        ausgabe = Path(ordner, "text")
        lauf = subprocess.run([optionen.whisper, "-m", str(modell), "-f", str(ton), "-l", sprache or "auto", "-mc", "0",
                               "-ml", str(ZEILE_ZEICHEN), "-sow", "-osrt", "-of", str(ausgabe)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors="replace")
        if lauf.returncode != 0:
            raise RuntimeError(f"Whisper endete mit {lauf.returncode}: {lauf.stderr.strip()[-300:]}")
        zeilen = zeilen_aus_srt(Path(f"{ausgabe}.srt").read_text(errors="replace"))
    if not zeilen:
        return None
    ziel = video.with_name(f"{video.stem}.{sprache or 'und'}.srt")
    zwischen = video.with_name(f".{video.stem}.srt.teil")
    zwischen.write_text(als_srt(zeilen), encoding="utf-8")
    os.replace(zwischen, ziel)
    return ziel


def folge_bearbeiten(video, ordner, pi, optionen, modell):
    namen = pi.namen(ordner)
    video_da = video.name in namen
    praefix = video.stem.lower() + "."
    untertitel_da = any(name.lower().startswith(praefix) and Path(name).suffix.lower() in UNTERTITEL_ENDINGEN for name in namen)
    if video_da and untertitel_da:
        print("  ist schon komplett auf dem Pi", flush=True)
        return
    nummer = folgennummer(video.name)
    if nummer and not video_da:
        for name in sorted(namen):
            if Path(name).suffix.lower() in VIDEO_ENDINGEN and folgennummer(name) == nummer:
                raise RuntimeError(f"Diese Folge gibt es auf dem Pi schon als „{name}“. Nichts hochgeladen, sonst wäre sie doppelt.")
    lokal = untertitel_von(video)
    if not untertitel_da and not lokal:
        print("  erstelle Untertitel …", flush=True)
        neu = untertitel_erstellen(video, optionen, modell)
        if neu:
            print(f"  {neu.name}", flush=True)
            lokal = [neu]
        else:
            print("  keine Sprache gefunden, also ohne Untertitel", flush=True)
    # Untertitel zuerst: Sobald der Server die Folge sieht, hat sie sie schon.
    for datei in lokal:
        if datei.name not in namen and not untertitel_da:
            print(f"  lade {datei.name} hoch", flush=True)
            pi.hochladen(datei, ordner)
    if not video_da:
        print("  lade das Video hoch …", flush=True)
        pi.hochladen(video, ordner)


def nur_untertitel(video, optionen, modell):
    """Erstellt fehlende Untertitel neben dem Video. Der Pi wird dafür nicht gebraucht."""
    vorhanden = untertitel_von(video)
    if vorhanden:
        print(f"  hat schon {vorhanden[0].name}", flush=True)
        return
    print("  erstelle Untertitel …", flush=True)
    neu = untertitel_erstellen(video, optionen, modell)
    print(f"  {neu.name}" if neu else "  keine Sprache gefunden, also ohne Untertitel", flush=True)


def main():
    teile = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    teile.add_argument("eingaben", nargs="+", type=Path, metavar="FOLGE_ODER_ORDNER")
    teile.add_argument("-n", "--nur-zeigen", action="store_true", help="nichts erstellen und nichts hochladen")
    teile.add_argument("--nur-untertitel", action="store_true", help="nur Untertitel neben den Videos erstellen, nichts hochladen")
    teile.add_argument("--ziel", help='Ordner auf dem Pi für alle Videos, zum Beispiel "Serien/Show/Season 1"')
    teile.add_argument("--sprache", help="Sprache festlegen (en, de, …) statt sie zu erkennen")
    teile.add_argument("--modell", default="small", help="base (schnell), small (Standard) oder medium (genauer), oder eine Modelldatei")
    teile.add_argument("--whisper", default="whisper-cli", help=argparse.SUPPRESS)
    teile.add_argument("--server", default="pi", help=argparse.SUPPRESS)
    teile.add_argument("--wurzel", default="/mnt/media", help=argparse.SUPPRESS)
    optionen = teile.parse_args()
    try:
        for programm in ("ffmpeg", "ffprobe", "rsync", "ssh", "curl"):
            if not shutil.which(programm):
                raise Abbruch(f"{programm} fehlt auf dem Mac.")
        if not optionen.nur_zeigen and not shutil.which(optionen.whisper):
            raise Abbruch("whisper-cli fehlt. Installieren mit: brew install whisper-cpp")
        if optionen.modell not in MODELLE and not Path(optionen.modell).is_file():
            raise Abbruch(f"Unbekanntes Modell: {optionen.modell}")
        ziel = ziel_pruefen(optionen.ziel) if optionen.ziel else None
        videos = videos_finden(optionen.eingaben)
        if not videos:
            raise Abbruch("Keine Videos gefunden.")
        if optionen.nur_untertitel:
            plan = [(video, None) for video in videos]
        else:
            pi = Pi(optionen.server, optionen.wurzel)
            plan = [(video, pi.bekannte_schreibweise(ziel or zielordner(video))) for video in videos]
        if optionen.nur_zeigen:
            for video, ordner in plan:
                if ordner is None:
                    print(f"{video.name}\n  {'hat schon Untertitel' if untertitel_von(video) else 'bekommt Untertitel'}")
                else:
                    print(f"{video.name}\n  nach {ordner}/")
            return 0
        modell = Path(optionen.modell) if optionen.modell not in MODELLE else modell_holen(optionen.modell)
        fehler = []
        for nummer, (video, ordner) in enumerate(plan, 1):
            print(f"[{nummer}/{len(plan)}] {video.name}" + (f"\n  nach {ordner}/" if ordner else ""), flush=True)
            try:
                if ordner is None:
                    nur_untertitel(video, optionen, modell)
                else:
                    folge_bearbeiten(video, ordner, pi, optionen, modell)
            except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as grund:
                print(f"  FEHLER: {grund}", file=sys.stderr, flush=True)
                fehler.append(video.name)
    except Abbruch as grund:
        print(grund, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nAbgebrochen. Ein neuer Lauf macht bei der nächsten offenen Folge weiter.", file=sys.stderr)
        return 130
    if fehler:
        print(f"{len(fehler)} von {len(plan)} nicht geschafft: " + ", ".join(fehler), file=sys.stderr)
        return 1
    if optionen.nur_untertitel:
        print(f"Fertig: {len(plan)} Videos. Hochgeladen ist noch nichts; das macht derselbe Befehl ohne --nur-untertitel.")
        return 0
    print(f"Fertig: {len(plan)} Videos. Der Server nimmt sie beim nächsten Scan in die Mediathek auf.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
