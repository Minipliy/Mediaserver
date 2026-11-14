# Mediaserver

**Deine eigene Musik, deine Filme und Serien, gestreamt von deinem eigenen Server statt von Spotify oder Netflix.** Mit iPhone- und iPad-App, Web-Player für den Browser und einem kleinen Server, der zum Beispiel auf einem Raspberry Pi bei dir zu Hause läuft.

> [!IMPORTANT]
> **Mit KI erstellt.** Der gesamte Code, die App, die Website-Texte und diese Dokumentation wurden mit künstlicher Intelligenz erstellt (Claude von Anthropic). Das hier ist **nicht meine eigene Arbeit**: Ich habe es mir gewünscht, ausprobiert und teile es. Es gibt keine Garantie, dass alles fehlerfrei ist. Benutzung auf eigene Verantwortung.

## Für wen ist das?

Für alle, die ihre **Privatsphäre** behalten wollen. Deine Medien liegen bei dir zu Hause, nicht bei einem Konzern. Niemand wertet aus, was du hörst oder schaust. Kein Abo, keine Werbung, kein Tracking. Die App fragt nur deinen eigenen Server.

## Selbst einrichten

👉 **[Schritt-für-Schritt-Anleitung für Einsteiger](docs/ANLEITUNG.md)**: ohne Vorkenntnisse, mit Raspberry Pi, in etwa 1–2 Stunden.

Kurz gesagt:

1. Raspberry Pi OS (64-bit) auf eine SD-Karte spielen und den Pi starten.
2. Auf dem Pi einen einzigen Befehl ausführen:
   ```
   curl -fsSL https://raw.githubusercontent.com/Minipliy/Mediaserver/main/scripts/pi-einrichten.sh | sudo sh
   ```
3. Tailscale einrichten, damit App und Browser den Server sicher erreichen.
4. Die App [Mediaserver aus dem App Store](https://apps.apple.com/de/app/mediaserver-eigene-medien/id6828504596) laden, Adresse und Token eintragen.

Website zum Projekt: <https://mediaserver.minipliy.net>

## Was alles geht

| Funktion | So funktioniert sie |
|---|---|
| Musik hören | Alben mit Cover (ein Ordner = ein Album), Interpreten mit Bild und Beschreibung, Titel; Zufallswiedergabe und Wiederholen (alle/einen); Playlists direkt am Song erstellen oder ergänzen; Wiedergabe im Hintergrund und über den Sperrbildschirm mit Cover steuern. |
| Filme und Serien streamen | Poster-Raster, Detailseiten mit Beschreibung, native Vollbild-Wiedergabe mit Drehen, AirPlay und Bild-in-Bild. Serien → Staffeln (numerisch sortiert) → Folgen anhand der Ordnerstruktur, mit Folgentiteln aus TVmaze. |
| Im Browser | Unter der Adresse des Servers läuft ein Web-Player: Anmeldung mit demselben Token wie in der App, dieselben Funktionen wie die App: Musik, Interpretenseiten, Playlists anlegen und bearbeiten, Lieblingssongs und -alben, Warteschlange, Songtexte, Schlaf-Timer, Lautstärke angleichen, Filme und Serien mit Gesehen-Abgleich, Intro überspringen, Untertitel, Musik finden, Hochladen, SSD durchsuchen, Herunterladen und Löschen vom Server (wenn erlaubt). Steuerung auch über die Medientasten. Keine fremden Skripte; nur Katalog-Cover kommen von Apples Bildserver. |
| Startseite | Die letzten vier geschauten Filme, Videos oder Serien und die letzten vier gespielten Playlists. Einstellungen über das Zahnrad. |
| Favoriten, Statistik, Warteschlange | Herz bei Songs, automatische Playlists (Lieblingssongs, Meistgehört, Zuletzt gespielt), „Als Nächstes spielen“/„Ans Ende“, Warteschlange umsortieren. Favoriten, Gesehen-Markierungen und Statistik liegen auf dem iPhone und werden über den Server zwischen deinen Geräten abgeglichen (braucht einen aktuellen Server). |
| Gesehen-Markierung | Folgen und Filme werden ab 93 % automatisch als gesehen markiert, manuell auch je Staffel. „Weiterschauen“ springt zur nächsten ungesehenen Folge. Im Vollbild: Geschwindigkeit 0,5×–2×, immer im Querformat und „Nächste Folge“. |
| Songtexte und Untertitel | Songtext-Knopf im Player: aus `.lrc`-Dateien neben dem Song, eingebetteten Tags, sonst von Genius; mit Zeitmarken von LRCLIB läuft er synchron mit. Der Server holt die Texte im Hintergrund vorab und speichert sie, die App lädt sie mit dem Song und legt sie bei Downloads mit ab. Untertitel aus `.srt`/`.vtt` mit gleichem Namen wie das Video, Sprache in den Einstellungen oder je Video wählbar. |
| Upload aus der App | Dateien oder ganze Ordner aus der Dateien-App direkt auf den Server laden (ein Ordner unter Musik = ein Album). Große Dateien laufen in Teilen im Hintergrund und setzen nach einem Abbruch oder Neustart an derselben Stelle fort (braucht einen aktuellen Server). Muss auf dem Server eingeschaltet werden, siehe [Anleitung](docs/ANLEITUNG.md). |
| Vorschaubilder, Übergänge, Schlaf-Timer | Der Server erzeugt mit FFmpeg einmalig Standbilder für Filme und Folgen ohne eigenes Bild (`MINIPLY_THUMBNAILS`). Musik: Ein-/Ausblenden zwischen Songs (aufeinanderfolgende Songs eines Albums laufen nahtlos ineinander), Lautstärke angleichen über ReplayGain-Tags oder vom Server gemessene Lautheit, „Intro überspringen“ bei Serien mit gleichem Vorspann in allen Folgen, Schlaf-Timer (Minuten oder Ende des Titels). Songs starten immer von vorne, Videos an der gespeicherten Stelle. Gastkünstler ("feat.") erscheinen auch auf ihrer eigenen Interpretenseite. Alben, Playlists und Staffeln lassen sich komplett herunterladen. |
| Downloads fortsetzen, automatisch laden | Downloads lassen sich pausieren und laufen auch nach einem Verbindungsabbruch oder App-Neustart an derselben Stelle weiter (braucht einen aktuellen Server). Ist der Server kurz weg, versucht die App es mit wachsenden Pausen rund zwei Stunden lang selbst und setzt danach fort, sobald er wieder antwortet. Ohne Verbindung bleibt die Bibliothek sichtbar (nicht Geladenes abgeblendet); „Im WLAN herunterladen“ merkt sich Titel, die starten, sobald das iPhone im WLAN ist. Playlists und Serien können automatisch offline gehalten werden: neue Titel und die 3 Folgen nach der zuletzt gesehenen, auf Wunsch nur im WLAN. „Gesehene Folgen und Filme entfernen“ löscht eine geladene Folge, sobald sie fertig geschaut ist. |
| Adaptives Video | Für Videos mit vorbereiteter HLS-Kopie passt sich die Qualität der Leitung an, einstellbar je Netz (siehe [Einrichtung](docs/SETUP.md#adaptives-video-mit-hls-optional)). Die Kopien sind optional und brauchen Platz und Rechenzeit; ohne sie spielt die App die normale Datei. |
| Wischgesten | Songzeile nach rechts wischen legt den Song in die Warteschlange. Im Mini-Player und im großen Player blättert seitliches Wischen zum nächsten oder vorherigen Song, halbes Wischen zeigt ihn als Vorschau. |
| Sprachen | Deutsch und Englisch, passend zur Sprache des iPhones. Ordnernamen auf der SSD wie „Musik“ oder „Serien“ bleiben unverändert. |
| Nahtlose Übergänge | Rund 30 Sekunden vor Songende bereitet die App den nächsten Titel vor, damit er ohne spürbare Pause anschließt. Vorspulen nutzt ihn sofort. Im Datensparmodus von iOS wird nicht vorgeladen. |
| Verbindungsabbrüche | Bricht die Verbindung ab, verbindet sich die App bis zu 5 Minuten lang automatisch neu und spielt an derselben Stelle weiter, bei Netzrückkehr sofort. Über Mobilfunk und Hotspot lädt sie standardmäßig 30 Sekunden voraus, damit kurze Einbrüche ein Video nicht anhalten. In den Einstellungen: Streaming über Mobilfunk (alles, nur Musik, aus), Puffer je Netz und ein Verbindungsstatus, der Internet, Server und SSD als Ursache unterscheidet und nicht abspielbare Dateien auflistet. |
| Ohne Internet abspielen | Musik, Filme und einzelne Serienfolgen auf das iPhone herunterladen. Fertige Downloads sind in einem eigenen Tab erreichbar und werden von dort lokal abgespielt. |
| Zu Hause Dateien hinzufügen | Die SSD im Finder als SMB-Netzlaufwerk öffnen und Dateien per Drag-and-drop kopieren, während sie am Pi angeschlossen bleibt. |
| Unterwegs vom Mac hochladen | Einen SSH-Tunnel zum VPS öffnen und dieselbe SSD-Freigabe im Finder verwenden. Der VPS erreicht den Pi über WireGuard. |
| Sammlung verwalten | Verzeichnisse ansehen, Dateien herunterladen und den verfügbaren SSD-Speicher prüfen. Originaldateien werden über die Finder-Freigabe verwaltet. |

## Wie es aufgebaut ist

| Komponente | Aufgabe |
|---|---|
| Raspberry Pi mit NVMe-SSD | Speichert die Originalmedien und betreibt die Rust-API. |
| Rust mit Axum | Liest die Bibliothek und Audio-Tags ein, prüft die Authentifizierung und liefert Dateien mit HTTP-Range-Unterstützung aus, damit Spulen ohne vollständigen Download möglich ist. |
| SQLite | Speichert Playlists und Wiedergabepositionen außerhalb der freigegebenen Mediendateien. |
| SwiftUI mit AVPlayer/AVKit | Stellt die Bibliothek auf dem iPhone dar und übernimmt Streaming, Wiedergabe und lokale Downloads. |
| Samba | Macht die SSD für den Finder zugänglich; eine getrennte Anmeldung erlaubt Dateiübertragungen vom Mac. |
| WireGuard und Caddy | Verbinden Pi und VPS verschlüsselt und stellen den HTTPS-Zugang für die App bereit. |

Der Server streamt Originaldateien oder vorab erzeugte iPhone-Wiedergabekopien **ohne Echtzeit-Transcoding**. Direkt unterstützte Formate bleiben unverändert. Für andere Codecs kann FFmpeg einmalig passende MP4-/M4A-Kopien vorbereiten; die App verwendet sie anschließend für Streaming und Downloads. Die Originale bleiben erhalten. Für Streaming unterwegs muss der Upload des Heimanschlusses die Bitrate der jeweils verwendeten Datei tragen.

Der Server streamt Originaldateien oder vorab erzeugte iPhone-Wiedergabekopien **ohne Echtzeit-Transcoding**. Für Formate, die das iPhone nicht direkt abspielt, kann FFmpeg einmalig passende Kopien erzeugen ([Medienformate](docs/MEDIA_FORMATS.md)).

## Dokumentation

| Dokument | Inhalt |
|---|---|
| [docs/ANLEITUNG.md](docs/ANLEITUNG.md) | Einrichtung für Einsteiger mit Raspberry Pi und Tailscale. |
| [docs/SETUP.md](docs/SETUP.md) | Fortgeschrittener Aufbau mit eigenem VPS, eigener Domain, WireGuard, Caddy und Samba. |
| [docs/EXTRAS.md](docs/EXTRAS.md) | Zusatzfunktionen: Musik über den Server laden, Untertitel erzeugen, Ausfall-Warnung, WLAN-Wächter, Netzlaufwerk. |
| [docs/MEDIA_FORMATS.md](docs/MEDIA_FORMATS.md) | Welche Dateien abspielbar sind und wie man andere umwandelt. |
| [docs/VIDEOS_HOCHLADEN.md](docs/VIDEOS_HOCHLADEN.md) | Videos mit automatisch erzeugten Untertiteln hochladen. |
| [docs/API.md](docs/API.md) | Die Schnittstelle des Servers. |

## Für Entwickler

| Pfad | Inhalt |
|---|---|
| `server/` | Rust-Server (Axum, SQLite) mit Tests; enthält auch den Web-Player (`server/web/`). |
| `ios/` | SwiftUI-App für iPhone, iPad und Mac (Catalyst) mit Regressionstests. |
| `scripts/` | Einrichtung, Prüfungen, Hilfsprogramme. |
| `deploy/` | Vorlagen für systemd, Caddy, WireGuard, Samba. |
| `web/` | Die statische Projekt-Website (erzeugt mit `scripts/build-website.py`). |

### Lokal auf dem Mac ausprobieren

Voraussetzungen: Rust 1.89 oder neuer, Xcode mit iOS-Simulator, Python 3.

```sh
python3 scripts/create-demo.py      # erzeugt Beispielmedien in ./media
scripts/dev-server.sh               # startet den Server auf http://localhost:8080
```

Beim ersten Start entsteht eine `.env` mit einem zufälligen Token. Dann `ios/Mediaserver.xcodeproj` in Xcode öffnen, Scheme **Mediaserver** im Simulator starten und `http://localhost:8080` mit dem Token aus `.env` eintragen (HTTP ist nur in Debug-Builds für `localhost` erlaubt). Für ein eigenes Gerät in Xcode eine eigene Bundle-ID und ein eigenes Signing-Team wählen. Der Web-Player läuft unter <http://localhost:8080/web/>.

Server für den Raspberry Pi bauen (vom Mac aus, mit [cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild)):

```sh
cargo zigbuild --release --manifest-path server/Cargo.toml --target aarch64-unknown-linux-musl
```

### Prüfen

```sh
scripts/check.sh
```

Prüft Rust-Formatierung, Backend-Tests, Clippy, auf dem Mac einen iOS-Simulator-Build und bei installiertem Caddy die Proxy-Vorlage. Die Backend-Tests prüfen echte Router-Anfragen einschließlich Authentifizierung, Byte-Ranges, HEAD, Ticket-Manipulation und Ablauf, Symlink-Austausch nach dem Scan, Verzeichnisse und Persistenz nach Neustart.

Auf dem Mac werden außerdem deterministische AppModel-Regressionen für Offline-Cache, gleichzeitige Anfragen und Verbindungswechsel ausgeführt. Für Player- und Download-Regressionen einen bestehenden iOS-Simulator starten und Folgendes ausführen:

```sh
MINIPLY_SIMULATOR_TESTS=1 scripts/check.sh
# Optional einen bestimmten bereits gestarteten Simulator wählen:
# MINIPLY_TEST_SIMULATOR_UUID=<UUID> MINIPLY_SIMULATOR_TESTS=1 scripts/check.sh
```

Die Simulatorprüfungen verwenden eigene temporäre Test-Apps und entfernen diese anschließend. Sie testen echte Player-/Downloadtypen; AppModel-Prüfungen ersetzen Netzwerk, Schlüsselbund und Downloadservice durch kontrollierte Testdoubles. Echte Hintergrundübertragungen auf dem iPhone sind damit noch nicht abgenommen.

Mit FFmpeg sind zusätzlich echte Format-/Aufbereitungsprüfungen verfügbar: `MINIPLY_FORMAT_TESTS=1 scripts/check.sh`. Für den gesamten Pfad aus FFmpeg, Server-API und iOS-Wiedergabe siehe [Formatprüfung](docs/MEDIA_FORMATS.md#prüfen).

## Lizenz

[MIT](LICENSE): Du darfst den Code frei nutzen, ändern und weitergeben, solange der Lizenzhinweis erhalten bleibt. Ohne Gewähr.
