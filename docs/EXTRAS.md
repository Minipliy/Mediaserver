# Zusatzfunktionen für Fortgeschrittene

> Dieses Projekt wurde mit KI (Claude von Anthropic) erstellt. Mehr dazu in der [README](../README.md).

Diese Funktionen sind optional und setzen meist den [fortgeschrittenen Aufbau](SETUP.md) mit eigenem VPS und den Skripten in `scripts/` voraus. Für die normale Nutzung brauchst du sie nicht; dafür reicht die [einfache Anleitung](ANLEITUNG.md).

Skripte, die einen VPS ansprechen, lesen dessen Adresse aus `~/.config/miniply/vps` (eine Zeile, zum Beispiel `root@203.0.113.10`) oder aus der Umgebungsvariable `MINIPLY_VPS`.

**Musik per Name laden:** Auf dem Mac lädt `scripts/musik-suchen.py "Künstler Album"` ein ganzes Album von YouTube Music auf den Pi, `-s` nur einen Song, `-n` zeigt vorher, was geladen würde. Auf dem Pi lädt `--neu-laden /mnt/media/Musik` vorhandene Songs in der neuen Qualität und unzensiert neu: gleicher Dateiname und alte Tags (Lieblingssongs und Playlists bleiben), die alte Datei kommt in den Papierkorb, Songs ohne sichere Quelle bleiben unverändert; ein abgebrochener Lauf macht weiter. Lade nur Musik, für die du die Rechte hast oder die frei verfügbar ist.

**Untertitel aus der Tonspur:** `scripts/folgen-hochladen.py "/Pfad/zu/den/Folgen"` erstellt auf dem Mac mit whisper.cpp (`brew install whisper-cpp`, Modell `small`) für jedes Video eine `Video.<Sprache>.srt` und lädt beides auf den Pi: `Show S01E02 …` nach `Serien/Show/Season 1`, alles andere nach `Filme`. Auf dem Pi wird nichts überschrieben, und eine dort schon vorhandene Folge kommt nicht doppelt dazu. `-n` zeigt vorher nur das Ziel, `--ziel` und `--sprache` legen Ordner und Sprache fest. `--nur-untertitel` erstellt nur die Untertitel neben den Videos und braucht den Pi nicht; derselbe Befehl ohne die Option lädt später Videos und Untertitel hoch. Schritt für Schritt: [docs/VIDEOS_HOCHLADEN.md](docs/VIDEOS_HOCHLADEN.md).

**Musik in der App finden:** In Debug- und Release-Builds sucht „Musik finden“ im Tab Musik über den Server, und der Pi lädt selbst herunter; das iPhone überträgt nur Suchergebnisse, Fortschritt und kleine Cover. Damit die Suche schnell antwortet, hält der Server eine eigene Kopie des iTunes-Katalogs (`music-catalog.sqlite` neben der Datenbank): jede Antwort 30 Tage (Wortsuchen 7), und im Hintergrund Songs und Alben der 5000 beliebtesten Künstler:innen, gereiht nach Fans bei Deezer (Startliste aus Deezer-Charts, ListenBrainz und Apple-Music-Charts). Nur Namen und Katalognummern, keine Songs und keine Cover; höchstens 5 GB (`MINIPLY_MUSIC_CATALOG_BYTES`), abschaltbar mit `MINIPLY_MUSIC_CATALOG=0`. Apple erlaubt etwa 20 Anfragen pro Minute, darum dauert die erste Füllung rund einen halben Tag; beliebte Künstler:innen kommen zuerst. Neue Cover speichert der Musik-Dienst mit 800 × 800 Pixeln und verkleinert ältere große beim Start. Songs legt der Musik-Dienst so ab, wie YouTube sie liefert (meist Opus mit 130–160 kbit/s in einer .m4a, die das iPhone ab iOS 17 abspielt), statt sie wie früher in AAC mit 256 kbit/s umzuwandeln: halb so groß, ohne zweite Umwandlung. Ältere große AAC-Dateien wandelt er nach und nach in Opus mit 160 kbit/s um, wenn kein Auftrag wartet; Name und Tags bleiben. Einrichten mit `scripts/setup-musik-dienst.sh` nach `scripts/update-pi.sh`. **Ausfall-Warnung:** `scripts/setup-ausfall-warnung.sh` richtet auf Pi und VPS eine Prüfung alle 5 Minuten ein. Antwortet der Mediaserver (vom Pi aus über den VPS) oder der Pi (vom VPS aus durch den Tunnel) zweimal nicht, kommt über Apples Push-Dienst eine Mitteilung direkt in die Mediaserver-App, und noch eine, wenn alles wieder läuft; kein fremder Dienst. In der App unter Einstellungen „Bei Ausfall benachrichtigen“ einschalten. Das Skript braucht einmal einen Push-Schlüssel von Apple (developer.apple.com → Keys → APNs): `sh scripts/setup-ausfall-warnung.sh ~/Downloads/AuthKey_XXXXXXXXXX.p8`. Die Push-Adressen holen die Wächter vom Server und behalten eine Kopie für die Zeit, in der der Pi weg ist. Absturzberichte der App (MetricKit) gehen an den eigenen Server nach `/var/lib/miniply/diagnostics`. Nach einmal `scripts/setup-ohne-passwort.sh` spielt `scripts/update-pi.sh` Server und Skripte ohne Passwort ein; erlaubt ist dafür nur `deploy/miniply-aktualisieren` (vier feste Dateien ersetzen, neu starten), alles andere fragt weiter nach dem Passwort. yt-dlp und Deno aktualisieren sich danach selbst: täglich und sofort, wenn ein Auftrag keinen einzigen Song laden konnte; danach versucht der Dienst ihn einmal erneut.

**Löschen aus der App:** Songs, Alben, Staffeln, Serien und Filme lassen sich über ihr Menü vom Server löschen, sobald `scripts/loeschen-einschalten.sh` gelaufen ist. Gelöschtes bleibt 14 Tage in `.miniply-papierkorb` auf der SSD und belegt so lange noch Platz.

**Genius:** Mit einem kostenlosen Client Access Token findet der Server über die offizielle API mehr Songtexte und Tracklisten. Das Token liegt in `~/.config/miniply/genius.env` (Zeile `MINIPLY_GENIUS_TOKEN=…`), `scripts/set-genius-token.sh` bringt es auf den Pi. Ohne Token leitet der Server die Adressen aus Künstler und Titel ab und findet weniger.

**Online-Infos:** Der Server sucht im Hintergrund Informationen und Bilder: Alben und Titel über die iTunes Search API (Genre, Erscheinungsdatum, Cover), fehlende Albumcover zusätzlich über MusicBrainz/Cover Art Archive, Interpreten, Alben und Filme über Wikipedia (zuerst deutsch), Serien über TVmaze (Beschreibung, Genres, Sender, Bewertung, Poster, Folgentitel). Ergebnisse und Bilder landen in der SQLite-Datenbank außerhalb der Medienfreigabe und werden je Eintrag nur einmal abgefragt (höchstens etwa eine Anfrage pro Sekunde). Übertragen werden dabei nur Namen aus der Bibliothek (Interpret, Album, Titel, Serien- oder Filmname), weder Token noch Dateipfade, und nicht vom iPhone aus. Abschalten mit `MINIPLY_ONLINE_METADATA=0`. Untertitelbeschaffung ist nicht enthalten.

Die Bibliothek unterstützt unter anderem **MOV, MP4, M4V, MKV, AVI, WebM und MPEG** sowie **MP3, AAC, M4A/ALAC, FLAC, WAV, AIFF, CAF, OGG/Opus und WMA**. Die Endung bezeichnet den Container; welche Codecs das konkrete iPhone abspielen kann, prüft die App an der tatsächlichen Datei und ihren Spuren.

Für nicht direkt abspielbare Dateien erzeugt die optionale Aufbereitung passende Kopien. Auf dem Mac mit installiertem FFmpeg:

```sh
python3 scripts/prepare-media.py ./media --dry-run
python3 scripts/prepare-media.py ./media
```

Danach in der App **Bibliothek neu einlesen**. In der Zeile erscheint beispielsweise „AVI · optimierte MP4-Kopie“. Quelle, Ordner und Medien-ID bleiben erhalten; es entstehen keine doppelten Bibliothekseinträge. Für neue Finder-Uploads kann die Aufbereitung auf dem Pi automatisch im Hintergrund laufen. [Formate, Qualität und Einrichtung](docs/MEDIA_FORMATS.md).

**WLAN-Ausfälle:** `scripts/setup-wlan-waechter.sh` richtet auf dem Pi einen Wächter ein, der etwa einmal pro Minute Router und VPS anpingt. Antwortet keiner von beiden, verbindet er das WLAN nach etwa 3 Minuten neu und lädt nach etwa 6 Minuten den Treiber neu, danach alle 10 Minuten wieder. Den Pi selbst startet er nicht neu. Was passiert ist, zeigt `journalctl -u miniply-wlan-waechter`.

## Netzlaufwerk im Finder (mit eigenem VPS)

Nach der Pi-Einrichtung im Heimnetz: Finder → **Gehe zu → Mit Server verbinden**, `smb://PI-LAN-IP/Medien`, Benutzer `mediashare`.

Unterwegs:

```sh
cd ~/Mediaserver
scripts/connect-remote-share.sh
```

Das Skript öffnet einen SSH-Tunnel zu deinem VPS (Adresse als `benutzer@adresse` in `~/.config/miniply/vps`) und anschließend `smb://mediashare@127.0.0.1:1445/Medien` im Finder. Das Samba-Passwort wird im Finder eingegeben. Terminal während des Kopierens geöffnet lassen, danach die Freigabe auswerfen und mit `Ctrl+C` den Tunnel beenden. Der SSH-Zugang verwendet den bereits lokal vorhandenen Schlüssel.

Anleitung und nötige Samba-Freigabe über `wg0`: [Einrichtung](docs/SETUP.md).
