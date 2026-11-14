# Videos mit Untertiteln auf den Server laden

So kommen Folgen und Filme mit Untertiteln vom Mac auf den Pi. Die Untertitel entstehen auf dem Mac aus der Tonspur des Videos. Sie sind in der gesprochenen Sprache, übersetzt wird nichts.

## Einmal einrichten

```bash
brew install whisper-cpp ffmpeg
```

Beim ersten Lauf lädt das Skript zusätzlich das Sprachmodell (`small`, knapp 500 MB). Es bleibt danach auf dem Mac.

Alle Befehle unten startest du im Projektordner:

```bash
cd ~/Desktop/Mediaserver
```

## Dateien richtig benennen

Der Dateiname entscheidet, wo das Video landet:

| Dateiname | Ziel auf dem Pi |
|---|---|
| `Show S01E02 Titel.mp4` | `Serien/Show/Season 1` |
| `Show.s10e05.1080p.mkv` | `Serien/Show/Season 10` |
| `Show - 3x07 - Titel.mkv` | `Serien/Show/Season 3` |
| alles andere, z. B. `Ein Film (2010).mp4` | `Filme` |

Unterstützt werden `.mp4`, `.m4v`, `.mov`, `.mkv`, `.avi` und `.webm`. Ordner werden samt Unterordnern durchsucht.

## Weg A: Alles in einem Schritt

Untertitel erstellen und direkt hochladen:

```bash
python3 scripts/folgen-hochladen.py "/Pfad/zu/den/Folgen"
```

## Weg B: Erst Untertitel, später hochladen

**1. Untertitel erstellen.** Der Pi muss dafür nicht erreichbar sein:

```bash
python3 scripts/folgen-hochladen.py --nur-untertitel "/Pfad/zu/den/Folgen"
```

Neben jedem Video liegt danach eine Datei wie `Show S01E02 Titel.en.srt`. Lass sie im selben Ordner und benenne das Video nicht um, sonst findet das Skript sie nicht mehr.

**2. Später hochladen.** Derselbe Befehl ohne die Option:

```bash
python3 scripts/folgen-hochladen.py "/Pfad/zu/den/Folgen"
```

Fertige Untertitel werden dabei nicht neu erstellt.

## Vorher nachsehen

Mit `-n` passiert nichts, das Skript zeigt nur den Plan:

```bash
python3 scripts/folgen-hochladen.py -n "/Pfad/zu/den/Folgen"
```

```bash
python3 scripts/folgen-hochladen.py -n --nur-untertitel "/Pfad/zu/den/Folgen"
```

Der erste Befehl zeigt die Zielordner und braucht den Pi. Der zweite zeigt, welche Videos noch Untertitel bekommen, und kommt ohne Pi aus.

## Optionen

| Option | Wirkung | Beispiel |
|---|---|---|
| `--sprache` | Sprache festlegen, statt sie erkennen zu lassen. Sinnvoll, wenn die Erkennung danebenliegt. | `--sprache de` |
| `--ziel` | Ordner auf dem Pi für alle angegebenen Videos festlegen. Muss in `Serien/` oder `Filme/` liegen. | `--ziel "Serien/Show/Season 1"` |
| `--modell` | `base` ist schneller, `small` der Standard, `medium` genauer. | `--modell medium` |

`--sprache` und `--modell` gelten beim Erstellen der Untertitel, `--ziel` beim Hochladen.

## Was das Skript von selbst beachtet

- **Nichts wird überschrieben:** Was auf dem Pi schon liegt, bleibt unverändert.
- **Keine doppelten Folgen:** Gibt es dieselbe Staffel und Folge dort unter anderem Namen, wird das Video nicht hochgeladen und als Fehler gemeldet.
- **Abbrechen ist unproblematisch:** Ein neuer Lauf macht bei dem weiter, was noch fehlt.
- **Serienname:** Gibt es die Serie auf dem Pi schon in anderer Groß- und Kleinschreibung, kommt die Folge in den vorhandenen Ordner.
- **Kein Text erkannt:** Das Video wird trotzdem hochgeladen, nur ohne Untertitel.

## Danach in der App

Der Server nimmt die Videos beim nächsten Scan in die Mediathek auf. Die Untertitelsprache wählst du in den App-Einstellungen oder je Video.

## Wenn etwas nicht klappt

| Meldung | Lösung |
|---|---|
| `whisper-cli fehlt` | `brew install whisper-cpp` |
| `ffmpeg fehlt auf dem Mac` | `brew install ffmpeg` |
| `Der Pi ist nicht erreichbar` | Verbindung mit `ssh pi` prüfen. Untertitel lassen sich trotzdem mit `--nur-untertitel` erstellen. |
| `Diese Folge gibt es auf dem Pi schon als …` | Die Folge ist schon da, es wurde nichts hochgeladen. |
| `Kein Serienname erkennbar` | Datei umbenennen oder `--ziel` angeben. |
| Falsche Sprache im Dateinamen oder Text | Die `.srt`-Datei löschen und mit `--sprache` neu erstellen. |
