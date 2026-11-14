# Hardware und Einrichtung

> **Für Fortgeschrittene.** Dieses Dokument beschreibt den Aufbau, mit dem das Projekt entstanden ist: Raspberry Pi zu Hause, eigener VPS mit eigener Domain, WireGuard-Tunnel, Caddy und Samba. Teile davon (Hyse, `minipliy.net`) gehören zur Umgebung des ursprünglichen Autors und sind nur als Beispiel stehen geblieben. Wer neu anfängt, nimmt die [einfache Anleitung](ANLEITUNG.md).

Diese Anleitung ist für den späteren Aufbau vorbereitet. Befehle gehören jeweils auf den ausdrücklich genannten Rechner. Die SSD enthält bereits Daten: **keine Formatierung, kein `mkfs`, kein Schreiben eines OS-Abbilds auf die SSD**. Raspberry Pi OS wird auf einer separaten microSD eingerichtet.

## Hardware vor dem Kauf

Ein Raspberry Pi 4 mit 1 GB ist für diese kleine API ohne Transcoding ein plausibler Ausgangspunkt; 2 GB bieten mehr Reserven beim Einlesen großer Bibliotheken und beim Bauen. Die reale Leistung mit deiner SSD und deinen Dateien ist noch zu messen. Nutze Ethernet und Raspberry Pi OS Lite **64-bit**, keinen Desktop.

Budgetziele, keine aktuellen Händlerangebote:

| Teil | Vorgesehene Obergrenze |
|---|---:|
| Gebrauchter Pi 4, möglichst inklusive Netzteil/Gehäuse | 50 € |
| USB-3-Gehäuse/Adapter für vorhandene NVMe-SSD | 20 € |
| microSD, falls nicht vorhanden | 10 € |
| Reserve für Kabel/Kühlung bzw. Netzteil | 20 € |

Unter 100 € hängt besonders davon ab, was beim gebrauchten Pi enthalten ist. Der Adapter muss **NVMe/PCIe** unterstützen und zur Baugröße der SSD passen; ein reines M.2-SATA-Gehäuse ist ungeeignet. Das Pi-4-Netzteil soll eine stabile 5-V/3-A-Versorgung bieten. Bei stromhungriger NVMe und USB-Aussetzern kommt ein aktiv versorgter USB-Hub infrage; das muss in das Gesamtbudget passen. Siehe [Pi-4-Spezifikation](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) und [Herstellerdokumentation zur Stromversorgung](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#power-supply).

## 1. Bestehenden VPS und Hyse schützen

Am 27.10.2026 per SSH geprüft:

- VPS: `DEINE-VPS-IP`, Benutzer `root`, Ubuntu 22.04 LTS, x86_64.
- Caddy 2.10.2 ist aktiv. Vorhandene Sites: `minipliy.net, www.minipliy.net` und `hyse.minipliy.net`.
- `https://minipliy.net` antwortet 301 auf `https://hyse.minipliy.net/`; Hyse antwortet ohne Anmeldung zunächst 302 und nach Weiterleitung 200.
- UFW war inaktiv, WireGuard war noch nicht installiert. Keine Firewall oder Netzwerkkonfiguration wurde verändert.

Miniply läuft auf dem **Pi**, nicht im Hyse-Projekt und nicht auf dessen Anwendungsport. Für den neuen Zugang wird später ein zusätzlicher Caddy-Siteblock für `media.minipliy.net` eingebunden. Bestehende Siteblöcke, Hyse-Code, Hyse-Datenbank und Hyse-Umgebungsdateien bleiben erhalten.

Unmittelbar vor einer tatsächlichen Änderung auf dem VPS Bestand erneut prüfen. Das Backup erhält vertrauliche Konfiguration und bleibt nur auf dem Server:

```sh
ssh root@DEINE-VPS-IP
sudo install -d -m 0700 /root/miniply-backups
sudo cp -p /etc/caddy/Caddyfile "/root/miniply-backups/Caddyfile.$(date +%Y%m%d-%H%M%S)"
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

Kein Caddy-Neuinstallieren, kein blindes Paket-Upgrade, kein Ersetzen der gesamten Caddy-Konfiguration und kein Firewall-Reset. Später nur den zusätzlichen Siteblock einfügen, mit dem **installierten** Caddy validieren und `systemctl reload caddy` verwenden. Hyse vor und nach dem Reload mit derselben URL prüfen. Falls sich Verhalten oder Weiterleitung ändern, die konkrete Sicherung zurückspielen, erneut validieren und reloaden. Einen fehlerhaften Entwurf nicht laden.

## 2. Pi vorbereiten

Mit Raspberry Pi Imager Raspberry Pi OS Lite 64-bit auf microSD installieren. Hostname, eigenen Benutzer, WLAN bei Bedarf und SSH-Zugang per öffentlichem Schlüssel festlegen. Hostschlüssel beim ersten Verbinden überprüfen. Private SSH-Schlüssel bleiben auf dem Mac.

Auf dem Pi:

```sh
sudo apt update
sudo apt install samba samba-vfs-modules wireguard acl build-essential pkg-config ca-certificates
uname -m
lsblk -f
```

`uname -m` soll `aarch64` ergeben. In `lsblk -f` die **vorhandene** SSD-Partition, UUID und das Dateisystem erkennen. Bei Unsicherheit an dieser Stelle erst das konkrete Gerät prüfen. Die Beispiel-`fstab` gilt nur für ext4. Für exFAT oder NTFS müssen Mount-Treiber, UID/GID, Masken und fehlende POSIX-ACLs gesondert berücksichtigt werden. Vor Änderungen ein Backup der SSD anlegen.

Bei bestätigter ext4-Partition:

```sh
sudo mkdir -p /srv/media
sudo cp -p /etc/fstab /etc/fstab.before-miniply
```

Die passende Zeile aus `deploy/fstab.example` mit der tatsächlichen UUID in `/etc/fstab` ergänzen. Anschließend:

```sh
sudo mount /srv/media
findmnt /srv/media
ls -la /srv/media
```

Die bestehenden Mediendateien müssen sichtbar sein. Der API-Dienst startet später ausschließlich, wenn `/srv/media` wirklich ein Mountpoint ist; eine fehlende SSD darf nicht durch den leeren Ordner auf der microSD ersetzt werden.

## 3. Benutzer und Finder-Freigabe

Auf dem Pi, einmalig:

```sh
sudo groupadd -f media
sudo useradd --system --no-create-home --gid media --shell /usr/sbin/nologin miniply
sudo useradd --no-create-home --gid media --shell /usr/sbin/nologin mediashare
sudo smbpasswd -a mediashare
```

Das Samba-Passwort wird lokal eingegeben. Falls ein Benutzer bereits existiert, dessen Gruppen prüfen und den `useradd`-Schritt nicht wiederholen.

Für das bestätigte ext4-Medienvolume Lesezugriff für `miniply`, Schreibzugriff für `mediashare` und vererbbare Rechte auf Verzeichnissen einrichten. Diese Befehle verändern Zugriffsrechte vorhandener Dateien, keine Inhalte:

```sh
sudo setfacl -R -m u:miniply:rX,u:mediashare:rwX /srv/media
sudo find /srv/media -type d -exec setfacl -m d:u:miniply:rX,d:u:mediashare:rwX {} +
```

Eigentümer und vorhandene ACLs vorher prüfen. Bei exFAT/NTFS diese ACL-Befehle nicht verwenden; dort werden Rechte über Mount-Optionen festgelegt.

`deploy/samba.conf.example` mit `/etc/samba/smb.conf` zusammenführen. Das tatsächliche Heimnetz statt `192.168.178.0/24` eintragen. `wg0` ist nur für den SSH-Weiterleitungszugriff vom VPS vorgesehen; `hosts allow` lässt hierfür genau `10.77.0.1` zu. SMB3-Verschlüsselung ist für die Freigabe erforderlich.

```sh
sudo testparm -s
sudo systemctl restart smbd
```

Nach dem Einrichten von WireGuard die Startreihenfolge und die Mount-Prüfung für Samba hinterlegen. Auf dem Pi aus dem Projektordner:

```sh
sudo install -d /etc/systemd/system/smbd.service.d
sudo install -m 0644 deploy/smbd-miniply.conf /etc/systemd/system/smbd.service.d/miniply.conf
sudo systemctl daemon-reload
sudo systemctl restart smbd
```

So wird `wg0` vor dem SMB-Start angelegt; ohne eingebundene SSD startet die Freigabe nicht. Kein Port 445 oder 139 am Heimrouter oder VPS öffentlich freigeben. Bei aktiver Pi-Firewall SMB nur vom tatsächlichen Heimnetz und von `10.77.0.1` über `wg0` erlauben; bestehende Regeln zuerst prüfen.

Finder im Heimnetz: `smb://PI-LAN-IP/Medien`, registrierter Benutzer `mediashare`. Zunächst eine kleine Testdatei hochladen und lesend vom API-Benutzer prüfen:

```sh
sudo -u miniply test -r /srv/media/DEINE_TESTDATEI
```

## 4. WireGuard Pi ↔ VPS

Vorher prüfen, dass `10.77.0.0/30` in keinem bestehenden Netz oder Tunnel verwendet wird. Auf dem VPS WireGuard installieren, ohne andere Dienste zu aktualisieren:

```sh
sudo apt update
sudo apt install wireguard
```

Auf **jedem Gerät getrennt** als root:

```sh
sudo -i
install -d -m 0700 /etc/wireguard
umask 077
wg genkey > /etc/wireguard/privatekey
wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey
cat /etc/wireguard/publickey
exit
```

Nur die **öffentlichen** Schlüssel zwischen den Geräten austauschen. Die privaten Schlüssel lokal in die jeweilige `wg0.conf` einsetzen, nicht im Chat teilen und nicht ins Projekt kopieren. Eine vorhandene `wg0.conf` nicht überschreiben; bei Namens- oder Netzkonflikt Vorlagen und Service entsprechend anpassen.

- VPS-Vorlage: `deploy/wireguard/vps-wg0.conf.example` → `/etc/wireguard/wg0.conf`.
- Pi-Vorlage: `deploy/wireguard/pi-wg0.conf.example` → `/etc/wireguard/wg0.conf`.

Beide Dateien root und Modus 0600. Auf dem VPS beziehungsweise in der STRATO-Netzwerkfirewall eingehend **UDP 51820** zulassen. Die bestehende Firewall nur um diese konkrete Regel ergänzen; nicht pauschal UFW aktivieren oder SSH-/Hyse-Regeln ersetzen. Am Heimrouter ist keine Portfreigabe nötig: der Pi initiiert die Verbindung. `PersistentKeepalive = 25` erhält die NAT-Zuordnung, wie im [WireGuard-Quickstart](https://www.wireguard.com/quickstart/) beschrieben.

Auf beiden Geräten:

```sh
sudo chmod 0600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

Vom VPS `ping 10.77.0.2`, vom Pi `ping 10.77.0.1`. Caddy und der SSH-Tunnel greifen als lokale Prozesse auf dem VPS auf den Pi zu. **Kein IP-Forwarding, kein NAT, keine Standardroute über den Tunnel** erforderlich.

## 5. Backend auf dem Pi installieren

Rust über eine geprüfte Toolchain von [rust-lang.org](https://www.rust-lang.org/tools/install) installieren; Version mindestens 1.89. Projektquellen vom Mac auf den Pi kopieren, ohne lokale Tokens, Build-Verzeichnisse oder Beispielmedien:

```sh
rsync -av --exclude server/target --exclude build --exclude media --exclude .env --exclude .git ./ PI-BENUTZER@PI-LAN-IP:~/miniply/
```

Die folgenden Installationsbefehle gelten für die Erstinstallation. Bei einem bereits eingerichteten Dienst den Abschnitt **Spätere Softwareupdates** verwenden.

Auf dem Pi:

```sh
cd ~/miniply
cargo build --release --locked --manifest-path server/Cargo.toml -j 1
sudo install -m 0755 server/target/release/miniply-server /usr/local/bin/miniply-server
sudo install -d -m 0700 /etc/miniply
if ! sudo test -e /etc/miniply/server.env; then
    sudo install -m 0600 deploy/server.env.example /etc/miniply/server.env
fi
sudo install -m 0644 deploy/miniply.service /etc/systemd/system/miniply.service
```

Auf 1 GB RAM kann selbst ein Build mit einem Job zusätzlichen Speicher brauchen. Dann kontrolliert auf einer geeigneten Linux-aarch64-Buildumgebung bauen oder für den Build begrenzt Swap bereitstellen. Ein auf dem Mac gebautes macOS-Binary läuft nicht auf dem Pi.

In `/etc/miniply/server.env` den Platzhalter lokal durch ein zufälliges Token ersetzen (`openssl rand -hex 32`). Das Beispiel-Token wird vom Server absichtlich abgelehnt. Nicht in Chat, Screenshots oder Shell-History kopieren. Das Token später direkt in der iPhone-App eingeben.

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now miniply
sudo systemctl status miniply
sudo journalctl -u miniply -n 50 --no-pager
```

Vom VPS `curl http://10.77.0.2:8080/healthz`. Erwartet: `{"status":"ok"}`. `/v1/library` muss ohne Bearer-Header 401 ergeben. Der Dienst ist nur an `10.77.0.2:8080` gebunden, hat Schreibrechte allein auf seinen Zustand und erhält die SSD im systemd-Sandbox-Namensraum lesend.

### Spätere Softwareupdates

Die obigen Startbefehle richten den Dienst erstmals ein. Bei einem späteren Update bleibt die vorhandene `/etc/miniply/server.env` mit dem eingerichteten Token erhalten. Zuerst Quellen übertragen, neu bauen und lokal prüfen. Auf dem Pi aus dem aktualisierten Projektordner:

```sh
cargo build --release --locked --manifest-path server/Cargo.toml -j 1
sudo install -d -m 0700 /var/backups/miniply
sudo cp -p /usr/local/bin/miniply-server /var/backups/miniply/miniply-server.previous
sudo cp -p /etc/systemd/system/miniply.service /var/backups/miniply/miniply.service.previous
sudo install -m 0755 server/target/release/miniply-server /usr/local/bin/miniply-server.next
sudo mv /usr/local/bin/miniply-server.next /usr/local/bin/miniply-server
sudo install -m 0644 deploy/miniply.service /etc/systemd/system/miniply.service
sudo systemctl daemon-reload
sudo systemctl restart miniply
sudo systemctl status miniply --no-pager
sudo journalctl -u miniply -n 50 --no-pager
```

Das Binary wird über eine neue Datei ersetzt, damit die laufende ausführbare Datei nicht direkt überschrieben wird. Danach vom VPS Health, fehlende Authentifizierung und von der App eine kleine Datei prüfen. `enable --now` allein startet einen bereits laufenden Dienst nach dem Austausch nicht neu.

Falls das Update nicht funktioniert, das gesicherte Binary über eine neue Datei zurückspielen, den gesicherten Dienst wiederherstellen, `daemon-reload` und `restart miniply` ausführen und dieselben Prüfungen wiederholen. Datenbank und Serverkonfiguration bleiben erhalten. Vor künftigen Datenbankschemaänderungen zusätzlich die unten beschriebene konsistente Datenbanksicherung anlegen.

### Nach Tunnel- oder SSD-Wartung

Wird WireGuard administrativ gestoppt, können seine abhängigen API-/Samba-Dienste ebenfalls stoppen. Nach dem Start des Tunnels deshalb die abhängigen Dienste ausdrücklich wieder starten. Für geplante SSD-Wartung zuerst Kopiervorgänge beenden, Finder-Freigabe auswerfen und auf dem Pi `sudo systemctl stop miniply smbd` ausführen. Erst danach das bestätigte Volume aushängen. Nach der Wartung:

```sh
sudo mount /srv/media
findmnt /srv/media
sudo mountpoint -q /srv/media
sudo systemctl start wg-quick@wg0
sudo wg show
sudo systemctl start miniply smbd
sudo systemctl status miniply smbd --no-pager
```

`mount` nur ausführen, wenn das Volume nicht bereits eingebunden ist. Vor dem Dienststart prüfen, dass der tatsächliche SSD-Inhalt vorhanden ist. Nach unerwarteter USB-Trennung zuerst Verbindung und Dateisystemzustand klären; anschließend Mount, Tunnel, Dienste, Finder-Zugriff und Streaming in dieser Reihenfolge prüfen.

## 6. DNS und HTTPS ergänzen

In der DNS-Verwaltung einen **A-Eintrag** `media.minipliy.net → DEINE-VPS-IP` ergänzen. Die bestehende Domain und `hyse.minipliy.net` beibehalten. Keinen AAAA-Eintrag setzen, solange IPv6 für diesen Dienst nicht eingerichtet ist.

Erst wenn der Pi vom VPS erreichbar ist und das DNS stimmt, den Siteblock aus `deploy/Caddyfile.example` zusätzlich in das gesicherte bestehende Caddyfile übernehmen. Keine `encode`-Kompression für Mediendateien ergänzen. Die Caddy-Dokumentation beschreibt die [automatische HTTPS-Einrichtung für Domain-Proxys](https://caddyserver.com/docs/quick-starts/reverse-proxy).

Auf dem VPS:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
curl -I https://media.minipliy.net/healthz
curl -I https://hyse.minipliy.net
curl -I https://minipliy.net
```

Zusätzlich die Hyse-Weiterleitung verfolgen und die eigentlichen Hyse-Funktionen mit dem bestehenden Account testen. Erfolg heißt: Miniply-Health 200, API ohne Token 401 und Hyse wie vor dem Reload erreichbar. Caddys normale Access-Logs für die Medien-Subdomain sind mit `log_skip` deaktiviert, weil Streaming-URLs begrenzte Zugangsgeheimnisse enthalten. Bei weiteren vorgeschalteten Proxys die Query-Strings ebenfalls nicht loggen.

## 7. Vom Mac außerhalb des Heimnetzes hochladen

Voraussetzungen: WireGuard auf dem VPS aktiv, Pi an `10.77.0.2`, Samba an dessen `wg0` erreichbar und SSH-TCP-Weiterleitungen für deinen VPS-Benutzer erlaubt.

Auf dem Mac:

```sh
cd ~/Mediaserver
scripts/connect-remote-share.sh
```

Der Tunnel verläuft `Mac 127.0.0.1:1445 → SSH zum VPS → WireGuard → Pi:445`. Der Finder öffnet die Freigabe automatisch und fragt nach dem Samba-Passwort. Die Dateien werden direkt zur SSD übertragen; auf dem VPS wird keine Kopie angelegt. Die Verbindung kann langsamer sein als zu Hause. Mit einer kleinen Testdatei beginnen; anschließend im Heimnetz beziehungsweise der App prüfen.

Bei belegtem lokalen Port:

```sh
MINIPLY_SMB_PORT=1446 scripts/connect-remote-share.sh
```

Die Portangabe in SMB-URLs wird vom macOS-SMB-Client unterstützt; die allgemeine Finder-Bedienung beschreibt [Apple](https://support.apple.com/de-de/guide/mac-help/mchlp1140/mac). Für die spätere Härtung kann ein eigener VPS-Tunnelbenutzer mit `PermitOpen 10.77.0.2:445` und einem separaten öffentlichen Schlüssel verwendet werden. Den bestehenden Root-Zugang erst nach erfolgreichem Test eines Ersatz-Zugangs ändern.

Große Dateien zunächst in einen versteckten Ordner auf der Freigabe kopieren, danach in den endgültigen Ordner verschieben. Der Scanner ignoriert versteckte Ordner. Während des Kopierens und bis zum Auswerfen der Freigabe das Tunnel-Terminal geöffnet lassen.

## 8. Abnahme und Backups

1. Datei im Heimnetz per Finder kopieren, in der App nach dem Scan sehen.
2. Mac über einen anderen Internetzugang verbinden, Tunnel starten und weitere Testdatei hochladen.
3. Musik und Video über Mobilfunk streamen, mehrfach vor- und zurückspulen.
4. Audio bei gesperrtem Bildschirm hören und Sperrbildschirmsteuerung prüfen.
5. Musik, Film und Serienfolge laden; im Download-Tab Vollständigkeit prüfen.
6. Flugmodus einschalten, App neu öffnen und alle drei lokalen Dateien abspielen; im Video spulen.
7. Pi neu starten: SSD-Mount, WireGuard, Samba und API prüfen.
8. Hyse nach jedem VPS-Konfigurationsschritt mit seinen bisherigen Funktionen prüfen.

Die SSD ist kein Backup. Wichtige Originale auf ein unabhängiges Medium sichern. Für Playlists und Positionen eine konsistente SQLite-Sicherung verwenden, etwa nach Installation von `sqlite3` auf dem Pi:

```sh
sudo sqlite3 /var/lib/miniply/miniply.sqlite ".backup '/DEIN-BACKUPZIEL/miniply.sqlite'"
```

Eine laufende WAL-Datenbank nicht nur als einzelne `.sqlite`-Datei kopieren. Konfigurationen mit Tokens oder privaten WireGuard-Schlüsseln ausschließlich verschlüsselt sichern. Ein Wiederherstellungstest mit einer kleinen Datei gehört zur Abnahme.

## 9. Weitere Medienformate automatisch aufbereiten

MOV und viele Audioformate können direkt abgespielt werden. Für inkompatible Codecs bereitet der optionale FFmpeg-Worker nach Finder-Uploads zusätzliche MP4-/M4A-Kopien vor. Die Vorlagen `deploy/miniply-prepare.service` und `.timer` laufen getrennt von der API und erhalten nur Schreibzugriff auf den verborgenen Wiedergabe-Cache. Einrichtung, Qualitätsprofile und Tests: [Medienformate](MEDIA_FORMATS.md#automatisch-nach-finder-uploads-auf-dem-pi).

## Upload aus der App (optional)

Standardmäßig liest der API-Dienst die SSD nur. Für **Vom iPhone hochladen** braucht er Schreibrechte. Dateien werden zuerst in den versteckten Ordner `.miniply-upload/` geschrieben und erst vollständig an ihren Platz gelegt; vorhandene Dateien werden nie überschrieben, versteckte Namen und `..` werden abgelehnt.

Auf dem Pi aus dem Projektordner:

```sh
# Gruppe "media" darf schreiben, neue Ordner erben die Gruppe
sudo chmod -R g+w /srv/media
sudo find /srv/media -type d -exec chmod g+s {} +
# Dienst darf schreiben (systemd-Erweiterung)
sudo install -d /etc/systemd/system/miniply.service.d
sudo install -m 0644 deploy/miniply-uploads.conf /etc/systemd/system/miniply.service.d/uploads.conf
# Upload einschalten
echo 'MINIPLY_UPLOADS=1' | sudo tee -a /etc/miniply/server.env
sudo systemctl daemon-reload
sudo systemctl restart miniply
```

Damit Finder-Uploads und App-Uploads sich gegenseitig ändern dürfen, in der Samba-Freigabe `[Medien]` `create mask = 0660` und `directory mask = 2770` setzen und `sudo systemctl restart smbd` ausführen. Zum Abschalten `MINIPLY_UPLOADS=0` setzen oder die Datei `uploads.conf` entfernen und den Dienst neu starten.

## Adaptives Video mit HLS (optional)

HLS-Kopien erlauben der App, die Videoqualität an die Leitung anzupassen. Sie liegen im versteckten Ordner `.miniply-hls` der SSD, die Originale bleiben unverändert. Ohne Kopie spielt die App die normale Datei.

Eine H.264-Quelle wird als oberste Stufe übernommen und belegt damit noch einmal ihre eigene Größe. Darunter entstehen 720p und 480p, soweit die Quelle größer ist. Das kostet Rechenzeit und Platz, deshalb zuerst messen:

```sh
sudo install -m 0755 scripts/prepare-media.py scripts/prepare-hls.py /usr/local/lib/miniply/
# Platzbedarf, ohne etwas zu ändern
sudo -u miniply python3 /usr/local/lib/miniply/prepare-hls.py /srv/media --dry-run | tail -1
# 30 Sekunden Probe je Stufe in einem temporären Ordner
sudo -u miniply python3 /usr/local/lib/miniply/prepare-hls.py /srv/media --benchmark
```

`1.00x Echtzeit` heißt: Eine Stunde Film braucht für diese Stufe eine Stunde. Einzelne Filme gehen mit `--path "Filme/Mein Film.mp4"`. Für die ganze Sammlung einmal von Hand starten; der Dienst läuft mit niedrigster Priorität und einem Thread:

```sh
sudo install -d -o miniply -g media -m 0755 /srv/media/.miniply-hls
sudo install -m 0644 deploy/miniply-hls.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start --no-block miniply-hls
```

Fertige Kopien erkennt der Server beim nächsten Scan. Eine geänderte Quelldatei macht ihre Kopie ungültig, bis sie neu erzeugt wird. Zum Entfernen: `sudo rm -rf /srv/media/.miniply-hls`.
