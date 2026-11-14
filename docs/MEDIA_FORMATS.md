# Medienformate und Wiedergabekopien

Stand: 28.10.2026.

Die App ist nicht auf MP3 und MP4 beschränkt. Sie prüft die tatsächliche Datei und ihre Audio-/Videospuren asynchron mit AVFoundation. Eine MOV-Datei kann direkt funktionieren, während eine andere MOV-Datei einen auf diesem Gerät ungeeigneten Codec enthält. Eine Dateiendung allein ist keine Zusage für Abspielbarkeit. [Apple: Medien asynchron laden](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously), [Apple: Container und Codecs prüfen](https://developer.apple.com/documentation/avfoundation/avurlasset/isplayableextendedmimetype(_:)).

## Unterstützte Eingänge

| Bereich | Beispiele in der Bibliothek | Wiedergabe |
|---|---|---|
| Musik | MP3, AAC, M4A, M4B, FLAC, WAV, AIFF/AIFC, CAF | Auf dem Gerät unterstützte Codecs direkt; bei Bedarf zusätzliche M4A-Kopie |
| Weitere Musik | OGG/OGA, Opus, WMA, APE, WV, WebA, AC3/EAC3, DTS, AMR, AU | Bei ungeeigneten Codecs zunächst mit FFmpeg vorbereiten |
| Videos | MOV/QT, MP4/M4V | Passende H.264-/HEVC- und Audiospuren direkt; sonst vorbereitete MP4-Kopie |
| Weitere Videos | MKV, AVI, WebM, MPEG/MPG/VOB, TS/MTS/M2TS, OGV, 3GP, WMV/ASF, FLV | Bei Bedarf vorbereitete MP4-Kopie |

Groß-/Kleinschreibung der Endung spielt keine Rolle. HLS-/M3U-/PLS-Playlistdateien werden nicht als Video oder Musik interpretiert. Kopiergeschützte oder beschädigte Dateien werden durch eine andere Endung nicht abspielbar. FFmpeg muss den jeweiligen Quellcodec decodieren können.

## Einmalige Aufbereitung

FFmpeg und ffprobe müssen auf dem ausführenden Rechner installiert sein. Auf dem Mac kann die Aufbereitung im lokalen Medienordner oder direkt auf der eingebundenen SSD-Freigabe laufen:

```sh
brew install ffmpeg
python3 scripts/prepare-media.py ./media --dry-run
python3 scripts/prepare-media.py ./media
```

Für nur eine Datei und optional größere ALAC-Musikkopien:

```sh
python3 scripts/prepare-media.py ./media --path 'Filme/Mein Film.mkv'
python3 scripts/prepare-media.py ./media --path 'Musik/Album/Titel.ogg' --audio-codec alac
```

`--dry-run` prüft die Dateien, schreibt aber keine Kopien. Direkt geeignete Dateien werden standardmäßig übersprungen. `--all` erzeugt auch für sie Kopien, `--force` erneuert vorhandene Kopien. `--watch 60` prüft neue Dateien wiederholt; `Ctrl+C` beendet den Prozess. Es wird jeweils nur eine Datei verarbeitet. Bestehende gültige Kopien werden wiederverwendet.

Die Ablage liegt verborgen unter `.miniply-playback/<Medien-ID>/` neben den Originalordnern. Ein Manifest bindet jede fertige Kopie an Quellpfad, Originalgröße und präzise Änderungszeit. Erst nach erfolgreicher Aufbereitung wird sie veröffentlicht. Der Backend-Scan blendet den Cache aus und ergänzt am Original die Variante, statt einen zweiten Titel anzulegen. Veränderte Originale machen ihre bisherige Kopie ungültig. Nach dem Kopieren auf ein Ziel mit anderen Zeitstempeln die Aufbereitung dort erneut ausführen.

### Qualität und Grenzen

- Musik wird standardmäßig als AAC mit 256 kbit/s, Stereo und 48 kHz vorbereitet. Mit `--audio-codec alac` verwendet die Kopie ALAC und behält Abtastrate und Kanäle bei; PCM-Gleichheit für 16-/24-Bit-Quellen ist automatisiert geprüft. ALAC-Kopien können deutlich größer werden. Für Float-/32-Bit-Quellen ist damit keine verlustfreie Umsetzung zugesagt.
- Geeignete H.264-Videospuren werden nach Möglichkeit ohne erneute Videocodierung in MP4 verpackt. Andernfalls entsteht H.264 mit maximal 1920×1080 beziehungsweise 1080×1920 und 30 Bildern/s. Video-Audio wird AAC-Stereo mit 192 kbit/s. Die Originalqualität bleibt in der Quelldatei erhalten.
- HDR-zu-SDR benötigt FFmpegs `zscale`-/Tonemapping-Filter. Fehlen sie im installierten Build, wird eine Fehlermeldung ausgegeben und keine fehlerhafte Kopie veröffentlicht. Im aktuell geprüften Homebrew-Build fehlt `zscale`; HDR-Konvertierung ist deshalb nicht abgenommen. HEVC mit passendem MOV/MP4-Tag kann direkt bleiben; die App prüft das konkrete Gerät.
- Verwendet werden die als Standard markierten Video-/Audiospuren, ersatzweise die jeweils erste geeignete Spur. Zusätzliche Tonsprachen, Untertitel und interaktive Menüs bleiben im Original und gehören nicht zur Wiedergabekopie.
- Das ist Vorverarbeitung, kein Live-Transcoding. Auf einem kleinen Pi kann ein langer Film viel Zeit benötigen. Währenddessen bleiben bereits geeignete Dateien abspielbar. Für große Sammlungen ist die Aufbereitung am Mac eine Alternative.

`+faststart` legt die MP4-Metadaten vor die Mediendaten und erleichtert progressive Wiedergabe. Netzwerkprotokolle und externe QuickTime-Referenzen sind bei der Aufbereitung nicht freigeschaltet. [FFmpeg: MOV/MP4](https://ffmpeg.org/ffmpeg-formats.html#MOV_002fMPEG_002d4_002fISOMBFF-muxers), [FFmpeg: lokale Protokolle](https://ffmpeg.org/ffmpeg-protocols.html), [FFmpeg: externe MOV-Spuren](https://ffmpeg.org/ffmpeg-formats.html#mov_002fmp4_002f3gp).

## Automatisch nach Finder-Uploads auf dem Pi

Voraussetzung ist die erfolgreich abgeschlossene Pi-/SSD-Einrichtung aus [SETUP.md](SETUP.md). Die folgenden Befehle sind dafür vorbereitete Schritte und wurden noch nicht auf echter Pi-Hardware ausgeführt. Im Projektordner auf dem Pi:

```sh
sudo apt install ffmpeg python3
sudo mountpoint -q /srv/media
sudo install -d -m 0755 /usr/local/lib/miniply
sudo install -m 0755 scripts/prepare-media.py /usr/local/lib/miniply/prepare-media.py
sudo install -d -m 0750 -o miniply -g media /srv/media/.miniply-playback
sudo install -m 0644 deploy/miniply-prepare.service deploy/miniply-prepare.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now miniply-prepare.timer
sudo systemctl start miniply-prepare.service
sudo journalctl -u miniply-prepare.service -f
```

Der Cache muss vor dem ersten Dienststart existieren. Die Unit gibt dem Worker Schreibzugriff nur auf diesen Unterordner; die Originalmedien bleiben in seiner Sandbox schreibgeschützt. Er verarbeitet mit einem Thread, niedriger Priorität und maximal 512 MiB Speicher. Der Timer startet frühestens zwei Minuten nach dem Booten und dann fünf Minuten nach dem Ende des letzten Laufs erneut. Parallele Aufbereitungen derselben Mediathek verhindert zusätzlich eine Dateisperre.

Nach Abschluss maximal das Scanintervall abwarten oder in der App **Server → Bibliothek neu einlesen** wählen. Zur Kontrolle `systemctl status miniply-prepare.timer miniply-prepare.service` verwenden. Die Units wurden lokal strukturell geprüft; Laufzeit, Speicherbedarf und Dateirechte müssen auf dem echten Pi abgenommen werden.

## App und Offline-Dateien

Die App zeigt beispielsweise „OGG · optimierte M4A-Kopie“ an. Streaming verwendet die gültige Kopie; **Herunterladen** speichert sie mit richtiger Endung und Dateigröße. Playlist-ID und Wiedergabeposition bleiben an das Original gebunden.

Eine schon vorhandene lokale Originaldatei wird nicht heimlich ersetzt. Ist sie inkompatibel, über ihr Menü **Lokale Kopie entfernen** und anschließend erneut herunterladen. Das entfernt nur die iPhone-Datei. Ein Wiedergabefehler startet keinen automatischen großen Streamingtransfer als Ersatz für einen lokalen Download.

## Prüfen

```sh
MINIPLY_FORMAT_TESTS=1 scripts/check.sh
# Zusätzlich echte Serverauslieferung und wiederverwendbare iOS-Fixtures prüfen:
cargo build --locked --manifest-path server/Cargo.toml
python3 scripts/check-media-formats.py --server-bin server/target/debug/miniply-server --keep-fixtures build/format-fixtures
# Einen bestehenden iOS-Simulator starten, dann den absoluten Fixture-Pfad angeben:
MINIPLY_PLAYBACK_FIXTURES="$PWD/build/format-fixtures" scripts/check-ios-playback.sh
```

Die Formatprüfung erzeugt nur temporäre Testdateien. Sie prüft echte Codecs, vollständiges Decoding, unveränderte Originale, Wiederverwendung, Größen/Manifestbindung und Fehlerfälle. Mit `--server-bin` kommen echte authentifizierte Bibliotheksabfragen, signiertes Range-Streaming sowie Original-/Wiedergabedownloads hinzu. Der iOS-Harness prüft anschließend AVPlayer-Wiedergabe mit laufender Zeit. Tests mit eigener Sammlung und einem echten iPhone bleiben für Gerätegrenzen und lange Dateien erforderlich.
