# API v1

Eine persönliche Bibliothek mit einem gemeinsamen API-Token. Kein Mehrbenutzersystem. Alle `/v1/`-Routen verlangen `Authorization: Bearer <TOKEN>`. `GET /healthz` ist öffentlich und verrät nur den Prozessstatus. Die vollständige Betriebsbereitschaft prüft `/v1/storage` mit Authentifizierung.

## Routen

| Methode | Pfad | Ergebnis |
|---|---|---|
| GET | `/v1/library?kind=audio&search=…&offset=0&limit=200` | `{items,total,offset,scanned_at,scan_errors}`; `scanned_at` ist der letzte Scan mit geänderten Dateien |
| GET | `/v1/files?path=Serien%2FName&offset=0&limit=200` | `{path,directories,files,total}` |
| GET | `/v1/storage` | SSD-Gesamtgröße, verfügbarer Platz, indexierte Bytes, Anzahl Dateien, Scanstatus |
| GET | `/v1/status` | Zustand des Pi für die Statusseite: Laufzeit, Last, Arbeitsspeicher, Temperatur, SSD, Lebenszeichen des Musik-Dienstes, gemessene Songs, Staffeln mit Intro, Stand des Musik-Katalogs (`music_catalog`: `artists_ready`, `artists_listed`, `bytes`, `limit_bytes`) |
| POST | `/v1/diagnostics` | Absturz- oder Hängebericht der App (MetricKit-JSON, höchstens 1 MB); landet in `/var/lib/miniply/diagnostics`, die neuesten 50 bleiben |
| POST | `/v1/push/devices` | Push-Adresse eines iPhones für Ausfall-Warnungen: `{"token": "<hex>", "environment": "production"\|"sandbox"}`; nach 90 Tagen ohne Meldung vergessen |
| GET | `/v1/push/devices` | Alle gemeldeten Push-Adressen, für die Ausfall-Wächter auf Pi und VPS |
| POST | `/v1/scan` | Scan abschließen, dann 204 |
| POST | `/v1/media/{id}/ticket` | `{path,expires_at}` für AVPlayer |
| GET | `/web/` | Web-Player für den Browser (ohne Token ausgeliefert; meldet sich mit dem Token an und nutzt nur diese API). `/` leitet dorthin weiter. Eigene Content-Security-Policy, nur Skripte vom Server selbst |
| GET / HEAD | `/stream/{id}?expires=…&signature=…` | Datei mit gültigem Streaming-Ticket |
| GET / HEAD | `/v1/files/{id}/download` | Datei als Attachment, Bearer erforderlich |
| GET / HEAD | `/v1/files/{id}/download?playback=true` | Vorbereitete Wiedergabekopie, falls gültig vorhanden; sonst Original |
| GET | `/v1/playlists` | Liste aller Playlists |
| POST | `/v1/playlists` | Neue Playlist, 201 mit Playlist |
| PUT | `/v1/playlists/{id}` | Playlist ersetzen, 200 mit Playlist |
| DELETE | `/v1/playlists/{id}` | 204; bei unbekannter ID 404 |
| GET | `/v1/metadata` | Ordner-Cover und Online-Infos: `{enabled,pending,covers,albums,artists,tracks,series,movies}` |
| GET | `/v1/artwork/{id}` | Bild: Bilddatei der Bibliothek, eingebettetes Audio-Cover oder Online-Bild (`web-…`) |
| GET | `/v1/lyrics/{id}` | Songtext `{synced?, plain?, instrumental, source}`: `.lrc`/`.txt` neben der Datei, eingebetteter Tag, sonst Text von Genius und Zeitmarken von LRCLIB, ohne Treffer zusätzlich die LRCLIB-Suche, NetEase Cloud Music (Zeitmarken) und lyrics.ovh (Text); gecacht, `source` nennt die Quelle (`file`, `tag`, `lrclib`, `genius`, `netease`, `lyrics.ovh`); 404 ohne Treffer |
| GET | `/v1/subtitles/{id}` | `.srt`/`.vtt`-Datei als UTF-8-WebVTT (`text/vtt`) |
| POST | `/v1/upload?path=Musik%2FAlbum&name=01.mp3` | Datei als Body hochladen; 201 `{path,bytes}`, 409 wenn vorhanden, 403 wenn `MINIPLY_UPLOADS` aus |
| POST | `/v1/media/delete` | `{ids:[…]}` (höchstens 5000) verschiebt Audio und Video in den Papierkorb: `{deleted,failed}`; 403 wenn `MINIPLY_DELETES` aus |
| GET | `/v1/music/search?q=…&kind=album` | Sucht im iTunes-Katalog (`album` oder `song`): `{results:[{id,kind,title,artist,album,year,track_count,seconds,cover}]}` |
| GET | `/v1/music/artist?name=…` | Überblick über einen Künstler im iTunes-Katalog: `{latest,popular,albums}` mit Einträgen wie bei der Suche. `latest`: die 5 neuesten Veröffentlichungen, `popular`: bis zu 20 eigene Songs nach Beliebtheit, `albums`: neueste zuerst. Name nicht gefunden: 404 |
| GET | `/v1/music/jobs` | `{service_online,jobs:[{id,kind,item_id,title,artist,cover,state,done,total,current,missing,message}]}`, neueste zuerst; `state`: `queued`, `running`, `done`, `partial`, `failed`, `cancelled` |
| POST | `/v1/music/jobs` | `{kind,item_id,title,artist?,cover?}` legt einen Auftrag an: 201; läuft derselbe schon: 200 mit diesem |
| DELETE | `/v1/music/jobs/{id}` | Laufend: 202, stoppt nach dem aktuellen Song. Sonst: 204, Eintrag entfernt |
| GET | `/v1/progress/{id}` | `{seconds,updated_at}`, zunächst 0 |
| PUT | `/v1/progress/{id}` | `{seconds:42.5, updated_at?}` speichern, dann 204. `updated_at` (Unix-Sekunden) ist, wann das Gerät die Stelle gespeichert hat, auch offline lange vorher; es gilt immer die neueste Stelle, ein später nachgereichter älterer Stand überschreibt also keinen neueren. Ohne Angabe gilt „jetzt“, Zeiten in der Zukunft werden auf jetzt begrenzt |
| GET | `/v1/music/follows` | `{follows:[{name,since}], loading}`: Künstler, denen gefolgt wird. `loading` heißt, der Musik-Dienst ist eingerichtet und lädt Neues |
| POST | `/v1/music/follows` | `{name, follow}` folgt (true) oder entfolgt (false); Antwort wie GET. Höchstens 500 Künstler. Der Server prüft alle 6 Stunden die Veröffentlichungen im iTunes-Katalog und legt für alles, was seit dem Tag des Folgens erschienen ist, einen Musik-Auftrag an (je Veröffentlichung einmal) |

`/v1/library`, `/v1/metadata`, `/v1/playlists` und `/v1/music/follows` senden ein `ETag`. Wer es als `If-None-Match` zurückschickt, bekommt bei unveränderter Antwort `304 Not Modified` ohne Inhalt.

`kind` ist optional und kann `audio`, `video` oder `file` sein. Limits werden auf 1–500 begrenzt. `path` ist ein relativer, exakt im Index vorhandener Verzeichnispfad; das Wurzelverzeichnis ist die leere Zeichenfolge. Verzeichnisse werden vollständig ausgegeben, Dateien paginiert. Alle Objekte verwenden JSON mit `snake_case`.

Ein Medienobjekt enthält `id`, `path`, `name`, `kind`, `title`, `artist`, `album`, `duration` (Sekunden oder null), `bytes` und `modified` (Unix-Sekunden). IDs sind SHA-256 des relativen Pfads; Umbenennen erzeugt eine andere ID. Playlist-Einträge und Wiedergabefortschritt beziehen sich auf diese IDs.

Videos mit passenden Untertiteldateien (`Film.srt`, `Film.de.srt`, `Film.en.forced.srt`) enthalten `subtitles: [{id, language, label, forced}]`; Songs mit `.lrc`-Datei oder eingebettetem Songtext `has_lyrics: true`. `/v1/storage` meldet `uploads` (true/false). Audio enthält optional `featured` (Gastkünstler aus „feat.“/„ft.“; `artist` ist dann nur der Hauptinterpret, `title` ohne „(feat. …)“), `artist_credit` und `gain_db` (ReplayGain aus den Tags, sonst vom Server mit FFmpeg gemessen, Bezug −18 LUFS), `censored: true`, wenn der Musik-Finder nur eine zensierte Fassung fand. Folgen enthalten `intro: {start, end}` in Sekunden, wenn der Server denselben Vorspann in allen Folgen der Staffel gefunden hat (Audio-Fingerabdruck der ersten 6 Minuten; abschalten mit `MINIPLY_ANALYSIS=0`). Alle Medien haben `added`: wann die Datei zuerst auftauchte; ein unter gleichem Namen ersetzter Song behält das Datum der ersten Fassung. `/v1/metadata` listet in `thumbnails` die Medien-IDs mit FFmpeg-Standbild, abrufbar als `/v1/artwork/thumb-<id>`.

Zusätzliche, optionale Felder (fehlen, wenn unbekannt): `album_key` (Ordner, der das Album bildet), `album_artist`, `track_number`, `disc_number`, `cover_id` (für `/v1/artwork/{id}`), bei Serienfolgen `series_key` (z. B. `Serien/Two and a Half Men`), `season_folder`, `season` und `episode`. Bei Audiodateien in einem Unterordner von `Musik` ist `album` der Ordnername.

Stream und Download senden ein `ETag` und beachten `If-Range`: Stimmt der Wert, gilt die `Range`-Anfrage, sonst kommt die ganze Datei. Darauf baut das Fortsetzen von Downloads in der App auf.

## HLS

Hat ein Video eine gültige Kopie aus `scripts/prepare-hls.py`, enthält es `hls: true`, und das Ticket nennt zusätzlich `hls_path`. Die Signatur steckt im Pfad `/stream/{id}/hls/{expires}/{signature}/…`, weil Segmente relativ zur Wiedergabeliste geladen werden. Es werden nur `master.m3u8`, `vN/index.m3u8` und `vN/segNNNNN.ts` ausgeliefert. Das Herunterladen nutzt weiterhin die normale Datei.

## Fortsetzbare Uploads

`GET /v1/uploads/{id}` liefert `{received}`, unbekannte IDs haben 0. `PUT /v1/uploads/{id}?offset=N&bytes=GESAMT&path=Musik%2FAlbum&name=01.mp3` hängt den Body an. `{id}` ist eine vom Client erzeugte UUID. Antworten: 200 `{received}`, 201 `{path,bytes}` beim letzten Teil, 412 bei falschem Offset (Status neu abfragen), 409 wenn das Ziel existiert. Was ankommt, bleibt auch bei Verbindungsabbruch erhalten. `DELETE /v1/uploads/{id}` verwirft den Stand, nach 14 Tagen räumt der Server selbst auf. Geht die Antwort auf den letzten Teil verloren, beantwortet derselbe Upload eine Wiederholung erneut mit 201. `POST /v1/upload` bleibt für ältere App-Versionen bestehen.

## Abgleich zwischen Geräten

`POST /v1/personal/sync` nimmt `{device, since, favorites, watched, plays, last_played}` mit den Änderungen des Geräts und liefert `cursor` sowie alles, was sich seit `since` geändert hat. `since` ist der `cursor` der letzten Antwort, 0 fordert alles an. Ist `cursor` kleiner als `since`, hat der Server seinen Stand verloren, und das Gerät sendet alles neu. Bei `favorites` und `watched` (`{id,on,at}`) gewinnt die neueste Änderung, auch beim Entfernen. `plays` (`{id,count}`) zählt je Gerät und liefert die Summe. `last_played` (`{id,at}`) behält den neuesten Wert.

## Löschen

`POST /v1/media/delete` nimmt Medien-IDs an, nie Pfade. Dateien wandern nach `.miniply-papierkorb/<Zeit>-<UUID>/<ursprünglicher Pfad>` und werden nach 14 Tagen endgültig gelöscht. Passende Untertitel und Songtexte wandern mit. Enthält ein Unterordner danach nur noch Bilder und versteckte Dateien, wandern diese mit und der Ordner verschwindet; Ordner direkt auf der SSD wie `Musik` bleiben. Vorbereitete Kopien (`.miniply-playback`, `.miniply-hls`) werden sofort entfernt. Zurückholen: Datei per Hand an den alten Pfad verschieben. `/v1/storage` meldet `deletes` (true/false).

## Musik über den Server laden

`GET /v1/music/preview?kind=album|song&id=…` liefert `{item, tracks: [{id, title, artist, seconds, explicit}]}`: die Tracklist vor dem Laden. Bei einem Album nimmt `item` die unzensierte und vollständigste Fassung; ein Auftrag verwendet deren `item.id`. `explicit` heißt: Geladen wird nur die als unzensiert markierte Aufnahme.

Die Routen unter `/v1/music` antworten 404, solange `scripts/setup-musik-dienst.sh` den Ordner `music-jobs` neben der Datenbank nicht angelegt hat. Der API-Server sucht nur im Katalog und legt Aufträge als Dateien ab. `miniply-music.service` führt sie mit `scripts/musik-suchen.py --dienst` nacheinander aus und meldet den Stand in `<id>.state.json`; er allein darf in `Musik` schreiben und yt-dlp starten. Ein Auftrag enthält eine Katalognummer und keinen Text für einen Befehl. Songs, die schon im Albumordner liegen, werden übersprungen; bei weniger als 2 GiB freiem Platz schlägt der Auftrag fehl. Abgeschlossene Aufträge bleiben 14 Tage in der Liste.

## Online-Infos und Bilder

`GET /v1/metadata` liefert Listen statt Objekt-Schlüsseln, damit Pfade nie als JSON-Schlüssel umgewandelt werden: `covers: [{directory, artwork}]`, `albums: [{key: album_key, title, artist, genre, release_date, year, track_count, copyright, artwork, description, short_description, wikipedia_url, description_language}]`, `artists: [{key: kleingeschriebener Name, genre, image, description, …}]`, `tracks: [{key: media_id, genre, release_date, year, album, track_number, track_count, disc_number, explicit}]`, `series: [{key: series_key, name, summary, genres, premiered, ended, status, network, rating, runtime, tvmaze_url, poster, description, episodes: [{season, number, name, airdate, runtime, summary}]}]`, `movies: [{key: media_id, title, year, poster, description, wikipedia_url}]`. `pending` zählt noch nicht abgefragte Einträge. Alle Felder außer `key` sind optional.

Ein Hintergrundprozess fragt die iTunes Search API, Wikipedia (de, dann en) und TVmaze ohne API-Schlüssel ab, mit mindestens 1,1 s Abstand zwischen Anfragen. Treffer werden 180 Tage, „nicht gefunden“ 14 Tage in SQLite (`metadata`, Bilder in `artwork`, höchstens 8 MiB je Bild) gespeichert; Netzwerk- und 5xx-Fehler werden nicht gespeichert, sondern später wiederholt. `MINIPLY_ONLINE_METADATA=0` schaltet die Abfragen ab; Ordner-Cover funktionieren weiter.

`GET /v1/artwork/{id}` akzeptiert eine Medien-ID einer Bilddatei (JPG, PNG, WebP, GIF, HEIC), die ID einer Audiodatei mit eingebettetem Cover oder `web-` plus 32 Hex-Zeichen. Antwort mit `Cache-Control: private, max-age=604800`. Bilddateien sind auf 25 MiB begrenzt.

Optional ergänzt `playback` eine vorbereitete Variante, beispielsweise `{"file_extension":"mp4","bytes":1234567}`. Ohne gültige Kopie fehlt das Feld. `path`, `name`, `bytes` und die Medien-ID beschreiben weiterhin das Original. Die App verwendet die Varianten-Endung/-Größe für ihre Offline-Datei. Auch bereits vorhandene Cache-/Clientdaten ohne `playback` bleiben lesbar.

Playlist-Eingabe: `{"name":"Abendmusik","media_ids":["<id>"]}`. Maximal 500 Audio-Einträge und 200 UTF-8-Bytes für den Namen. Die Reihenfolge wird gespeichert. Nicht mehr vorhandene Dateien bleiben als Playlist-Referenz erhalten, werden in der Wiedergabe übersprungen und können im Editor entfernt werden.

## Streaming

Unterstützt Einzelbereiche `bytes=0-1023`, `bytes=1024-` und `bytes=-1024`, Status 206 und `Content-Range`. Nicht erfüllbare oder mehrere Bereiche ergeben 416 mit `Content-Range: bytes */<size>`. HEAD liefert die Gesamtgröße ohne Body. Bei `If-Range` wird ohne eigenen Cache-Validator die vollständige Datei geliefert. Übertragungen werden in 64-KiB-Puffern gelesen.

Signiertes Streaming wählt eine gültige vorbereitete MP4-/M4A-Kopie automatisch. `Content-Type`, `Content-Length`, Range und Download-Dateiname entsprechen der tatsächlich ausgelieferten Datei. Originaldownloads ohne `playback=true` bleiben unverändert. Die breite Endungserkennung ordnet Medien ein und setzt passende Container-MIME-Typen; sie verspricht keinen geräteunabhängigen Codec-Support.

Das dauerhafte Token wird nur in HTTP-Headern übertragen. Für AVPlayer erhält die App eine auf **eine Datei** und **sechs Stunden** begrenzte signierte URL. Diese ist bis zum Ablauf selbst ein Zugangsgeheimnis und darf nicht geteilt oder in Access-Logs geschrieben werden. Nach Ablauf oder Token-Wechsel muss die App ein neues Ticket holen; bei einem Playerfehler startet die Play-Taste die Vorbereitung mit einem neuen Ticket erneut. Ein bereits laufender Response wird durch den Ablauf nicht nachträglich abgebrochen. Die Ticket-Signatur wird serverseitig geprüft, ein Ticket erlaubt weder Bibliothekszugriff noch Dateiverwaltung.

## Dateisicherheit und Zustand

Symlinks, versteckte Namen und Spezialdateien werden nicht indexiert. Dateiöffnungen laufen über ein verankertes `cap-std`-Verzeichnis, damit auch ein nachträglicher Symlink-Austausch keinen Zugriff außerhalb des Medienverzeichnisses erlaubt. Unter Unix verhindert nichtblockierendes Öffnen zusätzlich, dass eine nach dem Scan eingesetzte FIFO Streaming oder Metadatenlesen blockiert; nur reguläre Dateien werden akzeptiert. Die JSON-Eingabe ist auf 64 KiB begrenzt. Scannergrenzen: 100.000 besuchte Einträge und 64 Unterverzeichnisebenen; Fehler werden als `scan_errors` gemeldet. Kein Hashen ganzer Filmdateien beim Scan.

Der Scanner hält den Index im Speicher und verwendet Größe und Änderungszeit zum Wiederverwenden von Audio-Tags. Ein Scan läuft beim Start und regelmäßig im Hintergrund; das Intervall ist per Umgebungsvariable einstellbar. Bei gleichzeitigem Kopieren kann eine noch unvollständige Datei erscheinen: für große Transfers einen versteckten temporären Ordner verwenden und nach Abschluss ins sichtbare Ziel verschieben.

Vorbereitete Kopien liegen in `.miniply-playback/<id>/`. Version-1-Manifeste binden sie an relativen Originalpfad, Größe und Nanosekunden-Änderungszeit. Nur `playback.mp4` für Videos beziehungsweise `playback.m4a` für Audio mit passender positiver Größe werden akzeptiert. Manifest und jede Cache-Pfadkomponente dürfen keine Symlinks/Spezialdateien sein. Der Scan prüft Kopien auch bei wiederverwendeten Audio-Tags neu; die Auslieferung überprüft sie nochmals anhand des aktuellen Originals. Veraltete oder fehlende Kopien fallen auf das Original zurück. Es gibt keinen API-Endpunkt, der FFmpeg für eine beliebige angegebene URL startet.

Playlists und Positionen liegen in SQLite, außerhalb der Medienfreigabe. Das Backend hat keine API zum Hochladen, Umbenennen oder Löschen der Originale. Mac-Uploads nutzen die getrennt authentifizierte Samba-Freigabe; der API-Prozess erhält nur Lesezugriff auf die SSD.
