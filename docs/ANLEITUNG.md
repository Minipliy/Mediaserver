# Mediaserver selbst einrichten: Schritt für Schritt

> **Bitte zuerst lesen:** Dieses Projekt (der Code, die App und auch diese Anleitung) wurde mit künstlicher Intelligenz erstellt, mit Claude von Anthropic. Es ist **nicht meine eigene Arbeit**. Ich habe es mir gewünscht, ausprobiert und teile es hier. Es gibt keine Garantie, dass alles fehlerfrei funktioniert. Benutzung auf eigene Verantwortung.

## Für wen ist das?

Für Menschen, die ihre **Privatsphäre** schützen wollen. Statt Spotify, Netflix oder Google Fotos zu fragen, was du hören oder schauen darfst, und ihnen dabei alles über dich zu verraten, liegen deine Musik, Filme und Serien **bei dir zu Hause**. Kein Konto bei einem Streamingdienst, keine Werbung, keine Auswertung, was du hörst oder schaust.

Du brauchst **keine Vorkenntnisse**. Diese Anleitung erklärt jeden Schritt. Plane etwa **1 bis 2 Stunden** ein.

## So funktioniert es (in einfachen Worten)

Stell dir eine kleine Kiste vor, die bei dir zu Hause am Router hängt. Auf ihr liegen deine Medien. Diese Kiste ist ein **Raspberry Pi**, ein kleiner, günstiger Computer, ungefähr so groß wie eine Zigarettenschachtel. Auf ihm läuft das Programm **Mediaserver**.

Auf deinem iPhone oder iPad installierst du die App **Mediaserver**. Die App fragt die Kiste: „Welche Lieder hast du?“, und spielt sie ab, zu Hause und unterwegs. Am Computer geht das auch im Browser.

Damit die App die Kiste auch unterwegs sicher findet, ohne dass dein Zuhause für das ganze Internet offen steht, nutzen wir **Tailscale**. Das ist ein privater, verschlüsselter Tunnel zwischen deinen eigenen Geräten.

```
iPhone / iPad / Computer  ──(verschlüsselter Tunnel: Tailscale)──▶  Raspberry Pi zu Hause  ──▶  Festplatte mit deinen Medien
```

## Was du brauchst

| Was | Wofür | Ungefährer Preis |
|---|---|---|
| **Raspberry Pi 5** oder **Raspberry Pi 4** (mindestens 2 GB, besser 4 GB Arbeitsspeicher) | Die „Kiste“, auf der der Server läuft | 50–80 € |
| **Passendes Netzteil** (offizielles Raspberry-Pi-Netzteil) | Strom. Ein schwaches Handy-Ladegerät führt zu Abstürzen. | 10–15 € |
| **microSD-Karte**, mindestens 32 GB | Darauf kommt das Betriebssystem des Pi | 8–12 € |
| **Externe Festplatte oder SSD** mit USB | Darauf liegen deine Medien. Für den Anfang reicht auch die SD-Karte. | je nach Größe |
| **Netzwerkkabel** (empfohlen) | Verbindet den Pi mit deinem Router. WLAN geht auch, ist aber langsamer. | 5 € |
| **Ein Computer** (Mac oder Windows) | Nur für die Einrichtung | vorhanden |
| **iPhone oder iPad** mit iOS 17 oder neuer | Für die App | vorhanden |
| **microSD-Kartenleser** | Falls dein Computer keinen Kartenschlitz hat | 10 € |

Die App und alle Programme hier sind **kostenlos**.

## Ein paar Wörter, die du gleich liest

- **Server:** Ein Computer, der anderen Geräten etwas liefert. Hier: der Raspberry Pi, der deine Medien liefert.
- **Terminal:** Ein Fenster, in das man Befehle als Text eintippt. Keine Sorge: Du **kopierst** die Befehle aus dieser Anleitung und fügst sie ein.
- **SSH:** Eine Möglichkeit, vom Computer aus Befehle auf dem Pi auszuführen, als würdest du direkt davor sitzen.
- **Token:** Ein langes, zufälliges Passwort. Damit melden sich App und Browser bei deinem Server an.

**So fügst du einen kopierten Befehl im Terminal ein:**
- Mac: `Cmd` + `V`
- Windows (PowerShell): **Rechtsklick** ins Fenster

Danach immer die **Eingabetaste** (Enter) drücken.

---

## Schritt 1: Das Betriebssystem auf die SD-Karte spielen

Der Pi braucht, wie jeder Computer, ein Betriebssystem. Wir nehmen **Raspberry Pi OS**.

1. Lade auf deinem Computer den **Raspberry Pi Imager** herunter und installiere ihn: <https://www.raspberrypi.com/software/>
2. Stecke die microSD-Karte in deinen Computer.
3. Öffne den Raspberry Pi Imager. Er führt dich Seite für Seite durch die Einrichtung:
   1. **Gerät:** dein Modell, zum Beispiel „Raspberry Pi 5“.
   2. **Betriebssystem:** „Raspberry Pi OS (other)“ → **„Raspberry Pi OS Lite (64-bit)“**.
      Wichtig: **64-bit**. Die 32-Bit-Version funktioniert nicht.
   3. **Speicher:** deine microSD-Karte. Achtung, alles darauf wird gelöscht.
4. Danach fragt der Imager nach den **Anpassungen**. Trage ein:
   - **Hostname** (Name des Geräts im Netzwerk): `mediaserver`
   - **Lokalisierung:** Hauptstadt „Berlin“ (oder deine). Damit stimmen Zeitzone, Tastatur und WLAN-Land.
   - **Benutzer:** Denk dir einen Benutzernamen aus (zum Beispiel deinen Vornamen, klein geschrieben, ohne Leerzeichen) und ein gutes Passwort. **Schreib dir beides auf.**
   - **WLAN:** nur, wenn du kein Netzwerkkabel nutzt. Dann Name und Passwort deines WLANs eintragen.
   - **Fernzugriff (SSH):** **einschalten** und **Passwort-Anmeldung** wählen. Das Angebot „Raspberry Pi Connect“ brauchst du nicht.
5. Prüfe die **Zusammenfassung** und starte das **Schreiben**. Das dauert ein paar Minuten. Danach kannst du die Karte entnehmen.

> Ältere Versionen des Imagers zeigen statt der einzelnen Seiten ein Fenster „Einstellungen bearbeiten“ mit Reitern. Dort findest du dieselben Angaben; SSH steht im Reiter „Dienste“.

## Schritt 2: Den Pi anschließen und starten

1. Stecke die microSD-Karte in den Pi. Der Schlitz ist auf der Unterseite.
2. Verbinde den Pi per Netzwerkkabel mit deinem Router (wenn du kein WLAN eingerichtet hast).
3. Schließe die Festplatte an einen **blauen** USB-Anschluss an (das ist USB 3, schneller).
4. Stecke zuletzt das Netzteil ein. Der Pi startet von selbst.
5. Warte **etwa 3 Minuten**. Beim ersten Start richtet er sich ein.

## Schritt 3: Vom Computer aus mit dem Pi verbinden

1. Öffne das Terminal:
   - **Mac:** `Cmd` + `Leertaste` drücken, „Terminal“ tippen, Enter.
   - **Windows:** Startmenü öffnen, „PowerShell“ tippen, Enter.
2. Tippe Folgendes und ersetze `deinname` durch den Benutzernamen aus Schritt 1:
   ```
   ssh deinname@mediaserver.local
   ```
3. Beim ersten Mal kommt eine Frage wie „Are you sure you want to continue connecting?“. Tippe `yes` und Enter.
4. Gib dein Passwort aus Schritt 1 ein. **Beim Tippen siehst du keine Zeichen.** Das ist normal. Einfach tippen und Enter drücken.
5. Wenn vorne so etwas wie `deinname@mediaserver:~ $` steht, bist du **auf dem Pi**. Alle weiteren Befehle tippst du hier ein.

> Klappt `mediaserver.local` nicht? Schau in deinem Router (bei einer FRITZ!Box unter `fritz.box` → „Heimnetz“ → „Netzwerk“) nach der **IP-Adresse** des Geräts „mediaserver“, zum Beispiel `192.168.178.42`, und nimm dann `ssh deinname@192.168.178.42`.

## Schritt 4: Die Festplatte vorbereiten

> Hast du noch keine Festplatte und willst erst einmal ausprobieren? Dann **überspringe diesen Schritt**. Deine Medien landen vorerst auf der SD-Karte. Du kannst die Festplatte später nachrüsten.

> ⚠️ **Achtung:** In diesem Schritt wird die Festplatte **komplett gelöscht**. Nimm eine leere Festplatte oder sichere vorher alles, was darauf ist.

1. Lass dir alle Laufwerke anzeigen:
   ```
   lsblk -o NAME,SIZE,MODEL
   ```
   Du siehst eine Liste. Die SD-Karte heißt `mmcblk0`. Deine Festplatte heißt meistens **`sda`**. Erkennen kannst du sie an der Größe (SIZE), zum Beispiel `931,5G` bei einer 1-TB-Platte.
2. Lösche und formatiere die Festplatte. Ersetze `sda` nur, falls deine anders heißt:
   ```
   sudo wipefs -a /dev/sda && sudo mkfs.ext4 -F -L medien /dev/sda
   ```
   `sudo` bedeutet „als Administrator ausführen“. Eventuell fragt der Pi nach deinem Passwort.
3. Sorge dafür, dass der Pi die Festplatte bei jedem Start einbindet. Kopiere diese **vier Zeilen auf einmal**:
   ```
   sudo mkdir -p /srv/media
   grep -q 'LABEL=medien' /etc/fstab || echo 'LABEL=medien /srv/media ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload
   sudo mount -a
   ```
4. Prüfe, ob es geklappt hat:
   ```
   df -h /srv/media
   ```
   Hier sollte jetzt die Größe deiner Festplatte stehen.

> **Festplatte später nachgerüstet?** Dann nach diesem Schritt einfach Schritt 5 noch einmal ausführen, damit der Server auf der neuen Platte schreiben darf. Dateien, die vorher auf der SD-Karte unter `/srv/media` lagen, sind nach dem Einbinden nicht mehr zu sehen; lade sie danach erneut hoch.

## Schritt 5: Mediaserver installieren

Jetzt kommt der wichtigste Schritt, und er ist ganz einfach: **ein einziger Befehl**. Er lädt das Programm herunter, richtet alles ein und startet den Server.

```
curl -fsSL https://raw.githubusercontent.com/Minipliy/Mediaserver/main/scripts/pi-einrichten.sh | sudo sh
```

Das dauert ein paar Minuten, beim ersten Mal wegen der nötigen Programme auch zehn Minuten oder länger. Am Ende steht:

```
Fertig: Mediaserver läuft.

Dein Token (dein Passwort für App und Browser, nur für dich):

    3f9a…(eine lange Zeichenkette)…
```

**Kopiere dieses Token** und bewahre es gut auf, zum Beispiel in deinem Passwort-Manager. Du brauchst es gleich. Vergessen? Mit `sudo cat /etc/miniply/server.env` siehst du es wieder (Zeile `MINIPLY_TOKEN=`).

## Schritt 6: Tailscale einrichten (der sichere Tunnel)

Die App spricht aus Sicherheitsgründen nur **verschlüsselt** (über eine Adresse mit `https://`) mit deinem Server. Tailscale gibt dir genau so eine Adresse und verbindet deine Geräte privat miteinander. Dafür musst du **nichts an deinem Router einstellen**, und von außen kommt niemand an deinen Pi.

1. Lege dir ein kostenloses Konto an: <https://tailscale.com>. Für private Nutzung ist es kostenlos.
2. Installiere Tailscale **auf dem Pi** (im Terminal, wo du noch verbunden bist):
   ```
   curl -fsSL https://tailscale.com/install.sh | sh
   ```
3. Melde den Pi an:
   ```
   sudo tailscale up
   ```
   Es erscheint ein Link wie `https://login.tailscale.com/a/…`. Öffne ihn im Browser deines Computers und melde dich an. Danach geht es im Terminal von selbst weiter.
4. Schalte in Tailscale die **HTTPS-Zertifikate** ein: Öffne <https://login.tailscale.com/admin/dns>, scrolle ganz nach unten zu **HTTPS Certificates** und klicke **Enable HTTPS**.
5. Gib den Server im Tunnel frei:
   ```
   sudo tailscale serve --bg 8080
   ```
   Tailscale zeigt dir jetzt deine Adresse, etwa:
   ```
   https://mediaserver.tail1234.ts.net/
   ```
   **Schreib dir diese Adresse auf.** Das ist ab jetzt die Adresse deines Servers.
6. Installiere die **Tailscale-App auf deinem iPhone/iPad** (aus dem App Store), melde dich mit **demselben Konto** an und schalte die Verbindung ein. Du kannst sie dauerhaft eingeschaltet lassen. Sie leitet nur den Verkehr zu deinen eigenen Geräten durch den Tunnel, nicht dein normales Surfen.

> **Ehrlicher Hinweis zur Privatsphäre:** Deine Medien fließen verschlüsselt direkt zwischen deinen Geräten. Tailscale (die Firma) sieht sie nicht. Tailscale weiß aber, welche Geräte zu deinem Konto gehören. Wer auch das vermeiden will, kann den Server stattdessen über einen eigenen Server im Internet erreichbar machen. Das ist deutlich aufwendiger, siehe [Einrichtung für Fortgeschrittene](SETUP.md).

## Schritt 7: Die App verbinden

1. Lade **Mediaserver** aus dem App Store: <https://apps.apple.com/de/app/mediaserver-eigene-medien/id6828504596>
2. Öffne die App und trage unter **Dein Server** ein:
   - Ins obere Feld (dort steht grau `https://media.deine-domain.de`): deine Adresse aus Schritt 6, zum Beispiel `https://mediaserver.tail1234.ts.net`
   - Ins Feld **API-Token**: das Token aus Schritt 5
3. Tippe auf **Verbinden**. Fertig! 🎉

## Schritt 8: Musik, Filme und Serien draufladen

Am einfachsten im **Browser auf deinem Computer**:

1. Installiere Tailscale auch auf deinem Computer (<https://tailscale.com/download>) und melde dich mit demselben Konto an.
2. Öffne im Browser deine Adresse aus Schritt 6, zum Beispiel `https://mediaserver.tail1234.ts.net`.
3. Melde dich mit deinem **Token** an. Das ist der **Web-Player**: Hier kannst du alles auch direkt am Computer abspielen.
4. Gehe auf **Einstellungen** → **Hochladen**.
5. Wähle oben den Bereich (**Musik**, **Filme** oder **Serien**) und trage darunter den Ordner ein, etwa `Linkin Park/Hybrid Theory` für ein Album oder `Meine Serie/Season 1` für eine Staffel.
6. Klicke auf **Dateien auswählen** oder **Ganzen Ordner** und wähle die Dateien aus.

Hochladen geht auch direkt in der iPhone-App: **Einstellungen** → **Vom iPhone hochladen**.

### So sortierst du deine Dateien

Der Server erkennt deine Medien an den Ordnern:

```text
Musik/
└── Interpret/Album/          ← jeder Ordner ist ein Album
    ├── cover.jpg             ← ein Bild im Ordner wird zum Albumcover
    └── 01 - Titel.mp3
Filme/
├── Mein Film (2010).mp4
└── Mein Film (2010).jpg      ← Bild mit gleichem Namen = Filmplakat
Serien/
└── Name der Serie/
    ├── Season 1/
    │   └── S01E01 - Pilot.mp4
    └── Season 2/
        └── S02E01.mp4
```

Titel, Interpret und Albumname liest der Server aus den Musikdateien selbst. Beschreibungen, Cover und Folgentitel sucht er im Internet dazu (siehe „Was verlässt dein Zuhause?“ unten). Neue Dateien erscheinen nach spätestens einer Minute in der App.

**Welche Dateien gehen?** Musik als MP3, M4A/AAC, FLAC, WAV und andere. Videos am besten als **MP4** (Video H.264 oder HEVC, Ton AAC); das spielt jedes iPhone. MKV, AVI und andere Formate werden zwar erkannt, laufen aber nicht immer. Mehr dazu: [Medienformate](MEDIA_FORMATS.md).

---

## Wie halte ich alles aktuell?

- **App:** Sie aktualisiert sich über den App Store.
- **Server:** Verbinde dich wie in Schritt 3 mit dem Pi und führe einfach **noch einmal** den Befehl aus Schritt 5 aus. Dein Token und deine Medien bleiben erhalten.
- **Raspberry Pi OS:** Ab und zu `sudo apt update && sudo apt full-upgrade -y` ausführen.

## Was verlässt dein Zuhause?

Ehrlich und vollständig:

- **Deine Medien:** Nur zu deinen eigenen Geräten, verschlüsselt durch den Tunnel.
- **Namen von Alben, Interpreten, Serien und Filmen:** Der Server fragt damit bei der iTunes-Suche (Apple), Wikipedia, MusicBrainz, TVmaze, LRCLIB und Genius nach Beschreibungen, Covern und Songtexten. Er schickt dabei **nur die Namen**, keine Dateien und nichts über dich. Das kannst du abschalten: In `/etc/miniply/server.env` die Zeile `MINIPLY_ONLINE_METADATA=1` auf `0` ändern (`sudo nano /etc/miniply/server.env`, ändern, `Strg`+`O`, Enter, `Strg`+`X`) und dann `sudo systemctl restart miniply`.
- **Interpretenseiten im Web-Player:** Cover aus dem iTunes-Katalog lädt dein Browser direkt von Apple.
- **Tailscale:** Kennt deine Geräte (siehe Schritt 6), aber nicht deine Medien.
- Die App enthält **keine Werbung, kein Tracking und keine Analyse**.

## Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| `ssh: Could not resolve hostname mediaserver.local` | Der Pi ist noch nicht fertig gestartet (3 Minuten warten) oder dein Netzwerk kennt den Namen nicht. Nimm die IP-Adresse aus deinem Router (siehe Schritt 3). |
| `Permission denied` bei SSH | Benutzername oder Passwort falsch. Beim Passwort siehst du keine Zeichen, tippe es langsam. |
| „Nur 64-Bit-Systeme werden unterstützt“ | Du hast die 32-Bit-Version installiert. Schritt 1 wiederholen und **Raspberry Pi OS Lite (64-bit)** wählen. |
| „Hier läuft schon eine eigene Mediaserver-Einrichtung“ | Auf diesem Pi wurde Mediaserver schon auf anderem Weg eingerichtet. Das Skript lässt diese Einrichtung absichtlich in Ruhe. |
| Die App sagt „Server nicht erreichbar“ | Ist Tailscale auf dem iPhone **eingeschaltet**? Stimmt die Adresse mit `https://` vorne? Läuft der Pi? |
| Die App sagt, das Token sei falsch | Token nochmal genau kopieren, ohne Leerzeichen davor oder danach: `sudo cat /etc/miniply/server.env` |
| Neue Dateien erscheinen nicht | Eine Minute warten oder in der App unter **Einstellungen** „Bibliothek neu einlesen“. Stimmt die Ordnerstruktur (siehe oben)? |
| Ein Video spielt nicht | Das Format passt nicht zum iPhone. Am besten als MP4 (H.264/AAC) speichern. Siehe [Medienformate](MEDIA_FORMATS.md). |
| Ich will wissen, was der Server macht | `sudo journalctl -u miniply -n 50` zeigt die letzten Meldungen. `sudo systemctl status miniply` zeigt, ob er läuft. |

Du kommst nicht weiter? Öffne auf GitHub ein [Issue](https://github.com/Minipliy/Mediaserver/issues) und beschreibe, bei welchem Schritt es hakt und welche Meldung erscheint. **Schicke dabei niemals dein Token mit.**

## Für Fortgeschrittene

- Eigene Domain, eigener Server im Internet statt Tailscale, Netzlaufwerk im Finder: [Einrichtung für Fortgeschrittene](SETUP.md)
- Weitere Funktionen wie Musik über den Server laden, Untertitel erzeugen, Ausfall-Warnungen: [Zusatzfunktionen](EXTRAS.md)
- Die Schnittstelle des Servers: [API](API.md)
