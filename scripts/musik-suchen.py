#!/usr/bin/env python3
"""Sucht ein Album oder einen Song per Name und legt die Songs auf dem Pi ab.

    musik-suchen "Künstler Albumname"       ganzes Album
    musik-suchen -s "Künstler Songname"     nur dieser Song
    musik-suchen -n "..."                   zeigt nur, was geladen würde
    musik-suchen -o "Ordner" "..."          eigener Ordnername statt "Künstler - Album"
    musik-suchen --dienst ORDNER            arbeitet Aufträge aus der App ab (auf dem Pi)
    musik-suchen --neu-laden /mnt/media/Musik   lädt vorhandene Songs neu und ersetzt sie (auf dem Pi,
                                            die alte Datei kommt in den Papierkorb; mit -n nur zeigen)

Der iTunes-Katalog klärt die genaue Schreibweise und liefert das quadratische
Cover und die Tracklist (Ersatz: Genius), YouTube Music die Songs: nur die Albumaufnahme mit
höchstens 5 Sekunden neben der Länge aus dem Katalog, bei anstößigem Text gründlich gesucht
unzensiert (gibt es das nicht, die beste andere Fassung; beim Neu-Laden dann gar keine).
Gäste aus beiden Quellen landen als "Titel (feat. Gast)" in den Tags.
Ziel ändern mit MUSIK_ZIEL. Das Genius-Token liegt in ~/.config/miniply/genius.env.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.parse

USER_AGENT = "Mediaserver/1.0 (+https://mediaserver.minipliy.net; private media server)"
TARGET = os.environ.get("MUSIK_ZIEL", "pi:/mnt/media/Musik/")
TOKEN_FILE = os.path.expanduser("~/.config/miniply/genius.env")
GENIUS_TOKEN = None
# Wörter, die auf eine andere Fassung hinweisen, wenn der Songtitel sie nicht enthält.
COMMAND_SECONDS = 900
MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024
KEEP_JOBS_SECONDS = 14 * 24 * 3600
UPDATE_UNIT = "/etc/systemd/system/miniply-music-update.path"
UPDATE_WAIT_SECONDS = 600
UPDATE_POLL_SECONDS = 2
MUSIC_CLIENT = "1.20250101.01.00"
MUSIC_SONGS_ONLY = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
MAX_SOURCES = 3
# Mehr Abweichung von der Katalog-Länge heißt: andere Fassung, Intro oder Outro eines Videos.
MAX_DIFFERENCE_SECONDS = 5
# Offizielle Audios sind Videos und haben öfter einen Vorspann: dort strenger.
AUDIO_DIFFERENCE_SECONDS = 2
# Opus hat bei YouTube deutlich mehr Höhen als AAC. "drc" sind Fassungen mit angeglichener Lautstärke.
AUDIO_FORMAT = "ba[acodec=opus][format_id!*=drc]/ba[format_id!*=drc]/ba"
# Opus und AAC bleiben, wie YouTube sie liefert (in einer .m4a, die das iPhone ab iOS 17 abspielt):
# jede Umwandlung kostet Klang und machte die Dateien früher doppelt so groß (AAC mit 256 kbit/s).
# Nur anderes wird zu Opus, und ältere große AAC-Dateien werden es nach und nach auch.
OPUS_BITRATE = "160k"
LARGE_AAC = 200_000
# Ein .m4a-Name wählt bei ffmpeg sonst das iPod-Format, und das kennt kein Opus.
MP4 = ["-f", "mp4", "-movflags", "+faststart"]
# Steht im Kommentar-Tag, wenn es keine unzensierte Fassung gab; der Server zeigt es in der App an.
CENSORED_MARK = "Mediaserver: zensierte Fassung"
OTHER_VERSION = ("live", "cover", "karaoke", "reaction", "instrumental", "slowed", "sped up",
                 "nightcore", "remix", "8d", "acapella", "tutorial", "bass boosted", "1 hour")


def fetch(url, headers=None, data=None, browser=False):
    """Mit curl, das die Zertifikate des Systems kennt. Die Kopfzeilen gehen über
    die Standardeingabe, damit das Token nicht in der Prozessliste steht."""
    config = f'user-agent = "{"Mozilla/5.0" if browser else USER_AGENT}"\n'
    if data is not None:
        escaped = data.replace("\\", "\\\\").replace('"', '\\"')
        config += f'data-binary = "{escaped}"\n'
    config += "".join(f'header = "{name}: {value}"\n' for name, value in (headers or {}).items())
    result = subprocess.run(["curl", "-sSfL", "--max-time", "30", "-K", "-", url],
                            input=config.encode(), capture_output=True, check=False)
    if result.returncode != 0:
        raise OSError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def get_json(url, headers=None):
    return json.loads(fetch(url, headers))


def itunes(term, entity):
    query = urllib.parse.urlencode({"term": term, "entity": entity, "limit": 10, "country": "DE"})
    return get_json("https://itunes.apple.com/search?" + query).get("results", [])


def itunes_tracks(collection_id):
    url = f"https://itunes.apple.com/lookup?id={collection_id}&entity=song&country=DE"
    results = get_json(url).get("results", [])
    songs = [r for r in results if r.get("wrapperType") == "track" and r.get("kind", "song") == "song"]
    return sorted(songs, key=lambda s: (s.get("discNumber", 1), s.get("trackNumber", 0)))


def key(text):
    """Vergleichbare Form: "Numb (Ft. Jay-Z)" und "NUMB" sind gleich, "André" und "Andre" auch."""
    lower = unicodedata.normalize("NFKD", text).lower()
    for marker in ("(ft", "(feat", "[ft", "[feat", " ft.", " feat.", " featuring "):
        at = lower.find(marker)
        if at >= 0:
            lower = lower[:at]
    return "".join(c for c in lower if c.isalnum())


def guests_in_title(title):
    """ "Numb (feat. Jay-Z & Nas)" -> ["Jay-Z", "Nas"]."""
    found = re.search(r"[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+([^)\]]+)[\)\]]", title, re.IGNORECASE)
    return split_names(found.group(1)) if found else []


def split_names(names):
    return [n.strip() for n in re.split(r",|&", names) if n.strip()]


def merge_guests(artist, *groups):
    """Alle Namen außer dem Hauptinterpreten, ohne Doppelte."""
    seen, guests = {key(artist)}, []
    for name in (name for group in groups for name in group):
        if key(name) not in seen:
            seen.add(key(name))
            guests.append(name)
    return guests


def credited_title(track):
    """Der Server liest Gäste aus dem Titel-Tag."""
    title = track["title"]
    if not track.get("guests") or guests_in_title(title):
        return title
    return f'{title} (feat. {", ".join(track["guests"])})'


def plain_album(name):
    """ "FOMO - Single" -> "FOMO", "Take Care (Deluxe Version)" -> "Take Care"."""
    name = re.sub(r"\s+-\s+(Single|EP)$", "", name)
    return re.sub(r"\s*[\(\[][^)\]]*(deluxe|edition|version|remaster|bonus)[^)\]]*[\)\]]$", "",
                  name, flags=re.IGNORECASE).strip()


def best_match(query, results, name_field):
    """Das Ergebnis, dessen Künstler und Name am meisten Wörter der Suche abdecken."""
    words = set(re.findall(r"\w+", query.lower()))

    def score(result):
        found = set(re.findall(r"\w+", f"{result.get('artistName', '')} {result.get(name_field, '')}".lower()))
        return len(words & found) - 0.01 * len(found - words)

    return max(results, key=score) if results else None


def genius_token():
    global GENIUS_TOKEN
    token = os.environ.pop("MINIPLY_GENIUS_TOKEN", None)
    if token:
        GENIUS_TOKEN = token.strip()
    if GENIUS_TOKEN:
        return GENIUS_TOKEN
    try:
        with open(TOKEN_FILE, encoding="utf-8") as file:
            for line in file:
                if line.startswith("MINIPLY_GENIUS_TOKEN="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None


def genius_api(token, path, **params):
    url = f"https://api.genius.com/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return get_json(url, {"Authorization": f"Bearer {token}"}).get("response", {})


def genius_guests(song, artist):
    """Gäste eines Genius-Songs, auch die zweiten Namen gemeinsamer Veröffentlichungen."""
    names = [a["name"] for a in song.get("primary_artists") or []]
    names += [a["name"] for a in song.get("featured_artists") or []]
    return merge_guests(artist, names)


def genius_tracklist(artist, album, hints):
    """Songs des Albums bei Genius; leer, wenn Genius es nicht kennt. Ein Album
    ist nur über seine Songs erreichbar, `hints` sind Songtitel daraus."""
    token = genius_token()
    if not token:
        return []
    try:
        for words in [album, *hints[:3]]:
            hits = genius_api(token, "search", q=f"{artist} {words}", per_page=5).get("hits", [])
            songs = [h["result"] for h in hits if key(h["result"]["primary_artist"]["name"]) == key(artist)]
            for song in songs[:3]:
                found = genius_api(token, f"songs/{song['id']}")["song"].get("album") or {}
                if key(found.get("name", "")) == key(album):
                    titles, page = [], 1
                    while page and page <= 5:
                        part = genius_api(token, f"albums/{found['id']}/tracks", per_page=50, page=page)
                        titles += [{"title": t["song"]["title"], "guests": genius_guests(t["song"], artist)}
                                   for t in part.get("tracks", [])]
                        page = part.get("next_page")
                    return titles
    except OSError as error:
        print(f"Genius nicht erreichbar: {error}", file=sys.stderr)
    return []


def genius_song(artist, title):
    """Hauptinterpret und Gäste eines einzelnen Songs, wenn Genius ihn kennt."""
    token = genius_token()
    if not token:
        return None
    names = split_names(artist)
    try:
        hits = genius_api(token, "search", q=f"{artist} {title}", per_page=10).get("hits", [])
    except OSError as error:
        print(f"Genius nicht erreichbar: {error}", file=sys.stderr)
        return None
    for hit in hits:
        song = hit["result"]
        main = song["primary_artist"]["name"]
        if key(song["title"]) == key(title) and key(main) in {key(n) for n in names}:
            return {"artist": main, "guests": genius_guests(song, main)}
    return None


def song_key(title):
    """Wie key(), ohne Zusätze, die denselben Song bezeichnen: "Numb [Bonus Track]" ist "Numb"."""
    return key(re.sub(r"\s*[\(\[][^)\]]*(bonus|album version|original version|explicit)[^)\]]*[\)\]]", "",
                      title, flags=re.IGNORECASE))


def clock_seconds(text):
    """ "3:19" -> 199, None, wenn es keine Zeitangabe ist."""
    if not re.fullmatch(r"\d+(:\d\d){1,2}", text):
        return None
    seconds = 0
    for part in text.split(":"):
        seconds = seconds * 60 + int(part)
    return seconds


def music_song(row):
    """Eine Zeile der YouTube-Music-Suche: nur dort steht, ob ein Song die unzensierte Fassung ist."""
    columns = []
    for column in row.get("flexColumns", []):
        text = column.get("musicResponsiveListItemFlexColumnRenderer", {}).get("text", {})
        columns.append("".join(run.get("text", "") for run in text.get("runs", [])))
    video = (row.get("playlistItemData") or {}).get("videoId")
    if not video or len(columns) < 2:
        return None
    parts = [part.strip() for part in columns[1].split("\u2022")]
    badges = [badge.get("musicInlineBadgeRenderer", {}).get("icon", {}).get("iconType")
              for badge in row.get("badges", [])]
    return {"id": video, "title": columns[0], "artist": parts[0], "album": parts[1] if len(parts) > 2 else "",
            "duration": clock_seconds(parts[-1]), "explicit": "MUSIC_EXPLICIT_BADGE" in badges}


def music_rows(answer):
    """Alle Songzeilen der Antwort, wo auch immer sie darin stehen."""
    waiting, rows = [answer], []
    while waiting:
        part = waiting.pop()
        if isinstance(part, list):
            waiting.extend(reversed(part))
        elif isinstance(part, dict):
            if "musicResponsiveListItemRenderer" in part:
                rows.append(part["musicResponsiveListItemRenderer"])
            else:
                waiting.extend(reversed(list(part.values())))
    return rows


def music_search(words):
    """Songs bei YouTube Music. Dort stehen die Aufnahmen der Alben, keine Musikvideos."""
    body = {"context": {"client": {"clientName": "WEB_REMIX", "clientVersion": MUSIC_CLIENT, "hl": "en", "gl": "DE"}},
            "query": words, "params": MUSIC_SONGS_ONLY}
    try:
        answer = json.loads(fetch("https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
                                  {"Content-Type": "application/json", "Origin": "https://music.youtube.com"},
                                  data=json.dumps(body), browser=True))
    except (OSError, ValueError) as error:
        print(f"YouTube Music nicht erreichbar: {error}", file=sys.stderr)
        return []
    return [song for song in map(music_song, music_rows(answer)) if song]


def same_length(duration, seconds, allowed=MAX_DIFFERENCE_SECONDS):
    """Eine andere Länge heißt: Intro, Skit oder Outro des Videos oder eine andere Fassung."""
    return not seconds or (duration is not None and abs(duration - seconds) <= allowed)


def matching_songs(songs, artist, title, seconds, uncensored):
    names = [key(name) for name in split_names(artist)]
    return [song for song in songs
            if song_key(song["title"]) == song_key(title)
            and any(name in key(song["artist"]) for name in names)
            and same_length(song["duration"], seconds)
            and (song["explicit"] or not uncensored)]


def video_fallback(artist, title, seconds):
    """Für Songs ohne anstößigen Text, die YouTube Music nicht führt: nur Albumaufnahmen
    ("Künstler - Topic") oder offizielle Audios, jeweils mit der Länge aus dem Katalog."""
    result = subprocess.run(
        ["yt-dlp", "--flat-playlist", "--dump-json", "--no-warnings", f"ytsearch8:{artist} {title}"],
        capture_output=True, text=True, check=False, timeout=COMMAND_SECONDS)
    entries = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    names = [key(name) for name in split_names(artist)]
    wanted = song_key(title)
    albums, audios = [], []
    for entry in entries:
        name = (entry.get("title") or "").lower()
        channel = (entry.get("channel") or entry.get("uploader") or "").lower()
        if channel.endswith("- topic"):
            if (song_key(name) == wanted and any(n in key(channel) for n in names)
                    and same_length(entry.get("duration"), seconds)):
                albums.append(entry)
        elif ("official audio" in name and wanted in key(name) and any(n in key(channel + name) for n in names)
              and seconds and same_length(entry.get("duration"), seconds, AUDIO_DIFFERENCE_SECONDS)
              and not any(re.search(rf"\b{re.escape(word)}\b", name) and word not in title.lower()
                          for word in OTHER_VERSION)):
            audios.append(entry)
    return albums + audios


def find_on_youtube(artist, title, seconds, album="", uncensored=False, clean_fallback=True):
    """Die passenden Quellen, die beste zuerst, alle höchstens 5 Sekunden neben der Katalog-Länge.
    Hat der Song anstößigen Text, wird gründlich nach einer als unzensiert markierten Aufnahme
    gesucht. Gibt es keine, kommt mit `clean_fallback` die beste andere Fassung, sonst keine."""
    queries = [f"{artist} {title}", f"{artist} {title} {album}" if album else None,
               f"{title} {artist} explicit" if uncensored else None]
    found, seen = [], set()
    for query in filter(None, queries):
        for song in matching_songs(music_search(query), artist, title, seconds, False):
            if song["id"] not in seen:
                seen.add(song["id"])
                found.append(song)
        if any(song["explicit"] for song in found) or (found and not uncensored):
            break
    found.sort(key=lambda s: (not s["explicit"], key(s["album"]) != key(album),
                              abs(s["duration"] - seconds) if seconds and s["duration"] else 0))
    if uncensored:
        marked = [song for song in found if song["explicit"]]
        if marked:
            return marked[:MAX_SOURCES]
        if not clean_fallback:
            return []
        print(f"{title}: keine als unzensiert markierte Aufnahme, nehme eine andere Fassung", file=sys.stderr)
    if found:
        return found[:MAX_SOURCES]
    return video_fallback(artist, title, seconds)[:MAX_SOURCES]


def safe_name(name):
    name = re.sub(r'[/\\:*?"<>|]+', " ", name)
    return re.sub(r"\s+", " ", name).strip().lstrip(".") or "Unbekannt"


def probe(path, field):
    result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", field,
                             "-of", "default=noprint_wrappers=1:nokey=1", path],
                            capture_output=True, text=True, check=False)
    lines = result.stdout.split()
    return lines[0] if lines else None


def download_audio(video_id, work, seconds, title):
    """Lädt die Tonspur mit dem meisten Klang nach `work` und prüft die Länge. Opus und AAC
    bleiben unverändert, anderes wird zu Opus. Gibt die .m4a ohne Tags zurück, sonst None."""
    result = subprocess.run(
        ["yt-dlp", "-f", AUDIO_FORMAT, "--no-playlist", "--no-progress", "--no-warnings",
         "--max-filesize", "300M", "-o", os.path.join(work, "song.%(ext)s"),
         f"https://www.youtube.com/watch?v={video_id}"],
        check=False, timeout=COMMAND_SECONDS)
    files = [f for f in os.listdir(work) if f.startswith("song.")]
    if result.returncode != 0 or not files:
        return None
    source = os.path.join(work, files[0])
    try:
        duration = probe(source, "format=duration")
        if not same_length(float(duration) if duration else None, seconds):
            print(f"{title}: Länge {duration} statt {seconds}, verworfen", file=sys.stderr)
            return None
        codec = probe(source, "stream=codec_name")
        sound = ["-c", "copy"] if codec in ("opus", "aac") else ["-c:a", "libopus", "-b:a", OPUS_BITRATE]
        sound_file = os.path.join(work, "ton.m4a")
        result = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", source, "-map", "0:a", *sound,
                                 "-map_metadata", "-1", *MP4, sound_file], check=False)
        return sound_file if result.returncode == 0 else None
    finally:
        os.remove(source)


def download_song(video_id, folder, number, plan, position=None, censored=False):
    """Lädt den Song und legt ihn mit Tags als "01 Titel.m4a" in `folder`."""
    work = tempfile.mkdtemp(dir=folder, prefix=".lade-")
    try:
        track = plan["titles"][(position or number) - 1]
        title = track["title"]
        source = download_audio(video_id, work, track.get("seconds"), title)
        if not source:
            return False
        tagged = os.path.join(work, "tagged.m4a")
        result = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", source, "-map", "0:a", "-c", "copy", *MP4,
             "-map_metadata", "-1", "-metadata", f"title={credited_title(track)}", "-metadata", f"artist={plan['artist']}",
             "-metadata", f"album_artist={plan['artist']}", "-metadata", f"album={plan['album']}",
             "-metadata", f"track={number}/{plan.get('track_total') or len(plan['titles'])}",
             *(["-metadata", f"comment={CENSORED_MARK}"] if censored else []), tagged],
            check=False)
        if result.returncode != 0:
            return False
        shutil.move(tagged, os.path.join(folder, f"{number:02d} {safe_name(title)}.m4a"))
        return True
    finally:
        shutil.rmtree(work, ignore_errors=True)


def load_track(plan, track, folder, number, position):
    """Probiert die Quellen der Reihe nach, bis eine die Prüfung besteht."""
    wanted = track.get("uncensored", False)
    for video in find_on_youtube(plan["artist"], track["title"], track.get("seconds"), plan["album"], wanted):
        # Nur eine als unzensiert markierte Aufnahme gilt als unzensiert.
        if download_song(video["id"], folder, number, plan, position, censored=wanted and not video.get("explicit")):
            return True
    return False


# 800 × 800 reicht für Sperrbildschirm und Albumansicht; das hält ein Cover bei etwa 100 KB.
COVER_SIDE = 800
COVER_QUALITY = "4"
COVER_NAMES = ("cover.jpg", "tn_cover.jpg", "folder.jpg")
COVER_LARGE = 150_000


def cover_filter(square=True):
    crop = r"crop=min(iw\,ih):min(iw\,ih)," if square else ""
    return crop + f"scale='min({COVER_SIDE},iw)':-2"


def save_cover(url, folder):
    """cover.jpg, auch bei einer nicht quadratischen Vorlage genau 1:1, höchstens 800 Pixel breit."""
    if not url:
        return
    raw = os.path.join(folder, ".cover-vorlage")
    try:
        with open(raw, "wb") as file:
            file.write(fetch(url))
        subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", raw, "-frames:v", "1", "-update", "1",
             "-vf", cover_filter(), "-q:v", COVER_QUALITY, os.path.join(folder, "cover.jpg")],
            check=False)
    except OSError as error:
        print(f"Cover nicht geladen: {error}", file=sys.stderr)
    finally:
        if os.path.exists(raw):
            os.remove(raw)


def catalog_guests(song, artist):
    # "Earth, Wind & Fire" auf dem eigenen Album ist kein Künstler mit zwei Gästen.
    credit = song.get("artistName", "")
    names = [] if key(credit) == key(artist) else split_names(credit)
    return merge_guests(artist, names, guests_in_title(song["trackName"]))


def uncensored(song):
    """Auch die zensierte Katalogfassung hat ein unzensiertes Original."""
    return song.get("trackExplicitness") in ("explicit", "cleaned")


def album_plan(album):
    """Die Tracklist des Katalogs: genau das, was die App als Vorschau zeigt, mit der Länge
    jedes Songs. Genius ergänzt die Gäste und springt ein, wenn der Katalog nichts liefert."""
    artist, name = album["artistName"], plain_album(album["collectionName"])
    songs = itunes_tracks(album["collectionId"])
    genius = genius_tracklist(artist, name, [s["trackName"] for s in songs])
    if songs:
        guests = {key(track["title"]): track["guests"] for track in genius}
        tracks = [{"title": s["trackName"], "seconds": s.get("trackTimeMillis", 0) // 1000, "uncensored": uncensored(s),
                   "guests": merge_guests(artist, guests.get(key(s["trackName"]), []), catalog_guests(s, artist))}
                  for s in songs]
    else:
        tracks = [{"title": t["title"], "seconds": None, "guests": t["guests"]} for t in genius]
    return {"artist": artist, "album": name, "source": "iTunes" if songs else "Genius",
            "cover": album.get("artworkUrl100", "").replace("100x100bb", "1000x1000bb"), "titles": tracks}


def song_plan(song):
    artist, title = song["artistName"], song["trackName"]
    found = genius_song(artist, title)
    main = found["artist"] if found else artist
    guests = merge_guests(main, found["guests"] if found else [], catalog_guests(song, main))
    return {"artist": main, "album": plain_album(song.get("collectionName", title)), "source": "iTunes",
            "cover": song.get("artworkUrl100", "").replace("100x100bb", "1000x1000bb"),
            "track_total": song.get("trackCount"),
            "titles": [{"title": title, "guests": guests, "seconds": song.get("trackTimeMillis", 0) // 1000,
                        "uncensored": uncensored(song)}]}


def fullest_version(album):
    """Die Wortsuche findet oft nur die zensierte Fassung, und die hat manchmal weniger Songs."""
    if album.get("collectionExplicitness") == "explicit":
        return album
    url = f"https://itunes.apple.com/lookup?id={album['artistId']}&entity=album&limit=200&country=DE"
    try:
        results = get_json(url).get("results", [])
    except (OSError, KeyError, ValueError):
        return album
    same = [r for r in results if r.get("wrapperType") == "collection"
            and key(r.get("collectionName", "")) == key(album["collectionName"])]
    return max(same + [album], key=lambda r: (r.get("collectionExplicitness") != "cleaned", r.get("trackCount", 0)))


def plan_album(query):
    album = best_match(query, itunes(query, "album"), "collectionName")
    return album_plan(fullest_version(album)) if album else None


def plan_song(query):
    song = best_match(query, itunes(query, "song"), "trackName")
    return song_plan(song) if song else None


def lookup(item_id):
    """Eintrag des iTunes-Katalogs; die App wählt Alben und Songs per Nummer aus."""
    results = get_json(f"https://itunes.apple.com/lookup?id={item_id}&country=DE").get("results", [])
    return results[0] if results else None


def already_there(folder, number, title):
    """Ob dieser Song schon im Albumordner liegt, etwa vom letzten Versuch."""
    prefix = f"{number:02d} {safe_name(title)}."
    return os.path.isdir(folder) and any(name.startswith(prefix) for name in os.listdir(folder))


def write_json(path, value):
    """Über eine Zwischendatei: Der Server liest nie eine halbe Datei."""
    temporary = f"{path}.tmp"
    with open(temporary, "w", encoding="utf-8") as file:
        json.dump(value, file, ensure_ascii=False)
    os.replace(temporary, path)


class Cancelled(Exception):
    pass


def tools_stamp():
    """Ändert sich, sobald yt-dlp oder Deno ersetzt wurden."""
    stamps = []
    for tool in ("yt-dlp", "deno"):
        path = shutil.which(tool)
        stamps.append(os.stat(path).st_mtime_ns if path else None)
    return stamps


def update_tools(jobs, cancel_path):
    """Bittet miniply-music-update um neue Werkzeuge und wartet darauf.
    True, wenn wirklich etwas Neues da ist und sich ein zweiter Versuch lohnt."""
    if not os.path.exists(UPDATE_UNIT):
        return False
    before = tools_stamp()
    flag = os.path.join(jobs, "update-wanted")
    with open(flag, "w", encoding="utf-8"):
        pass
    deadline = time.monotonic() + UPDATE_WAIT_SECONDS
    while os.path.exists(flag) and time.monotonic() < deadline:
        if os.path.exists(cancel_path):
            raise Cancelled
        time.sleep(UPDATE_POLL_SECONDS)
    if os.path.exists(flag):
        os.remove(flag)
        return False
    return tools_stamp() != before


def run_job(job, jobs, target, retried=False):
    """Ein Auftrag der App: Fortschritt in <id>.state.json, Songs nach `target`.
    Lädt kein einziger Song, kommt zuerst ein Update und dann ein zweiter Versuch."""
    job_id = job["id"]
    state_path = os.path.join(jobs, f"{job_id}.state.json")
    cancel_path = os.path.join(jobs, f"{job_id}.cancel")
    state = {"state": "running", "done": 0, "total": 0, "current": None, "missing": [], "message": None}

    def report(**changes):
        state.update(changes)
        write_json(state_path, state)

    report()
    item = lookup(job["item_id"])
    if not item:
        report(state="failed", message="Nicht mehr im Katalog gefunden.", finished_at=int(time.time()))
        return
    plan = album_plan(fullest_version(item)) if job["kind"] == "album" else song_plan(item)
    folder_name = safe_name(f'{plan["artist"]} - {plan["album"]}')
    final = os.path.join(target, folder_name)
    numbers = [item.get("trackNumber", 1)] if job["kind"] == "song" else None
    report(total=len(plan["titles"]), artist=plan["artist"], album=plan["album"], source=plan["source"],
           folder=folder_name)
    if shutil.disk_usage(target).free < MIN_FREE_BYTES:
        report(state="failed", message="Auf der SSD ist zu wenig Platz.", finished_at=int(time.time()))
        return
    base = tempfile.mkdtemp(dir=target, prefix=".miniply-lade-")
    try:
        folder = os.path.join(base, folder_name)
        os.makedirs(folder)
        missing, added = [], 0
        for position, track in enumerate(plan["titles"], 1):
            if os.path.exists(cancel_path):
                raise Cancelled
            number = numbers[0] if numbers else position
            report(current=track["title"], done=position - 1)
            if already_there(final, number, track["title"]):
                continue
            try:
                loaded = load_track(plan, track, folder, number, position)
            except (subprocess.TimeoutExpired, OSError):
                loaded = False
            if loaded:
                added += 1
            else:
                missing.append(track["title"])
            report(missing=missing)
        if added:
            save_cover(plan["cover"], folder)
            if os.path.exists(os.path.join(final, "cover.jpg")) and os.path.exists(os.path.join(folder, "cover.jpg")):
                os.remove(os.path.join(folder, "cover.jpg"))
            subprocess.run(["chmod", "-R", "ug=rwX,o=rX", base], check=True)
            subprocess.run(["rsync", "-rt", folder, target], check=True)
            with open(os.path.join(jobs, "rescan"), "w", encoding="utf-8"):
                pass
        everything_failed = len(missing) == len(plan["titles"])
        message = None
        if everything_failed and not retried:
            report(current="yt-dlp wird aktualisiert …", done=0)
            if update_tools(jobs, cancel_path):
                run_job(job, jobs, target, retried=True)
                return
            message = "Kein Song geladen. Auf YouTube gab es keinen passenden Treffer, oder der Download ist gerade blockiert."
        elif everything_failed:
            message = "Kein Song geladen, auch nicht nach dem Update von yt-dlp."
        report(state="failed" if everything_failed else "partial" if missing else "done",
               done=len(plan["titles"]) - len(missing), current=None, finished_at=int(time.time()),
               message=message)
    except Cancelled:
        report(state="cancelled", current=None, finished_at=int(time.time()))
    finally:
        shutil.rmtree(base, ignore_errors=True)
        if os.path.exists(cancel_path):
            os.remove(cancel_path)


def clean_old_jobs(jobs):
    limit = time.time() - KEEP_JOBS_SECONDS
    for name in os.listdir(jobs):
        if not name.endswith(".state.json"):
            continue
        path = os.path.join(jobs, name)
        try:
            with open(path, encoding="utf-8") as file:
                finished = json.load(file).get("finished_at")
        except (OSError, ValueError):
            continue
        if finished and finished < limit:
            os.remove(path)
            request = os.path.join(jobs, name.replace(".state.json", ".json"))
            if os.path.exists(request):
                os.remove(request)


def next_job(jobs):
    """Ältester Auftrag ohne Ergebnis. Ein beim Neustart laufender fängt neu an,
    schon abgelegte Songs überspringt er dann."""
    waiting = []
    for name in os.listdir(jobs):
        if not name.endswith(".json") or name.endswith(".state.json"):
            continue
        path = os.path.join(jobs, name)
        state = path.replace(".json", ".state.json")
        try:
            with open(path, encoding="utf-8") as file:
                job = json.load(file)
            if os.path.exists(state):
                with open(state, encoding="utf-8") as file:
                    if json.load(file).get("state") != "running":
                        continue
        except (OSError, ValueError):
            continue
        waiting.append((job.get("created", 0), name, job))
    return min(waiting, key=lambda item: item[:2])[2] if waiting else None


def shrink_covers(target):
    """Große Cover von früher auf 800 Pixel verkleinern; nur ersetzen, was wirklich kleiner wird."""
    saved = 0
    for folder, _, files in os.walk(target):
        if os.path.basename(folder).startswith("."):
            continue
        for name in files:
            if name.lower() not in COVER_NAMES:
                continue
            path = os.path.join(folder, name)
            temporary = os.path.join(folder, ".kleiner-" + name)
            try:
                before = os.path.getsize(path)
                if before <= COVER_LARGE:
                    continue
                done = subprocess.run(
                    ["nice", "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", path, "-frames:v", "1",
                     "-update", "1", "-vf", cover_filter(square=False), "-q:v", COVER_QUALITY, temporary],
                    check=False)
                if done.returncode == 0 and 0 < os.path.getsize(temporary) < before:
                    saved += before - os.path.getsize(temporary)
                    os.replace(temporary, path)
            except OSError as error:
                print(f"Cover {path} nicht verkleinert: {error}", file=sys.stderr)
            finally:
                if os.path.exists(temporary):
                    os.remove(temporary)
    if saved:
        print(f"Cover verkleinert, {saved // 1000} KB frei.")
    return saved


def shrink_song(path):
    """Eine große AAC-Datei (früher 256 kbit/s) als Opus mit 160 kbit/s: klingt gleich, braucht
    rund 40 % weniger Platz. Name und Tags bleiben, damit Playlists und Lieblingssongs bleiben.
    Gibt die gesparten Bytes zurück, 0 wenn nichts zu tun war oder es nicht geklappt hat."""
    if probe(path, "stream=codec_name") != "aac":
        return 0
    tags, duration, bitrate = file_tags(path)
    if bitrate < LARGE_AAC or duration <= 0:
        return 0
    temporary = os.path.join(os.path.dirname(path), ".kleiner-" + os.path.basename(path))
    try:
        result = subprocess.run(
            ["nice", "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", path, "-map", "0:a", "-c:a", "libopus",
             "-b:a", OPUS_BITRATE, "-map_metadata", "0", *MP4, temporary], check=False, timeout=COMMAND_SECONDS)
        if result.returncode != 0:
            return 0
        new_tags, new_duration, _ = file_tags(temporary)
        before, after = os.path.getsize(path), os.path.getsize(temporary)
        # Nur ersetzen, was vollständig, mit denselben Tags und wirklich kleiner ist.
        if abs(new_duration - duration) > 0.5 or new_tags.get("title") != tags.get("title") or after >= before:
            print(f"{path}: Umwandlung verworfen", file=sys.stderr)
            return 0
        os.chmod(temporary, os.stat(path).st_mode & 0o777)
        os.replace(temporary, path)
        return before - after
    except (subprocess.TimeoutExpired, OSError) as error:
        print(f"{path} nicht verkleinert: {error}", file=sys.stderr)
        return 0
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def large_songs(target):
    """Alle großen AAC-Dateien, nach Pfad sortiert."""
    found = []
    for folder, folders, files in os.walk(target):
        folders[:] = sorted(f for f in folders if not f.startswith("."))
        for name in sorted(files):
            path = os.path.join(folder, name)
            if name.lower().endswith(".m4a") and probe(path, "stream=codec_name") == "aac" \
                    and file_tags(path)[2] >= LARGE_AAC:
                found.append(path)
    return found


def serve(jobs, target):
    """Läuft dauerhaft als eigener Dienst; der API-Server selbst darf nicht in die Musik schreiben."""
    for name in os.listdir(target):
        if name.startswith(".miniply-lade-"):
            shutil.rmtree(os.path.join(target, name), ignore_errors=True)
    shrink_covers(target)
    waiting, saved = None, 0
    while True:
        with open(os.path.join(jobs, "heartbeat"), "w", encoding="utf-8"):
            pass
        clean_old_jobs(jobs)
        job = next_job(jobs)
        if not job:
            # Ohne Auftrag einen großen Song verkleinern; Aufträge aus der App gehen immer vor.
            if waiting is None:
                waiting = large_songs(target)
            if waiting:
                song = waiting.pop(0)
                if os.path.exists(song) and shrink_song(song):
                    saved += 1
                    with open(os.path.join(jobs, "rescan"), "w", encoding="utf-8"):
                        pass
                if not waiting:
                    print(f"{saved} große Songs als Opus gespeichert.")
            else:
                time.sleep(3)
            continue
        beat = Heartbeat(jobs)
        beat.start()
        try:
            run_job(job, jobs, target)
        except Exception as error:  # Ein kaputter Auftrag darf die Warteschlange nicht anhalten.
            print(f'Auftrag {job.get("id")} fehlgeschlagen: {error}', file=sys.stderr)
            write_json(os.path.join(jobs, f'{job["id"]}.state.json'),
                       {"state": "failed", "done": 0, "total": 0, "current": None, "missing": [],
                        "message": "Der Auftrag ist fehlgeschlagen.", "finished_at": int(time.time())})
        finally:
            beat.stop()


class Heartbeat:
    """Meldet dem Server auch während langer Downloads, dass der Dienst lebt."""

    def __init__(self, jobs):
        self.path = os.path.join(jobs, "heartbeat")
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.done.set()
        self.thread.join()

    def run(self):
        while not self.done.wait(10):
            with open(self.path, "w", encoding="utf-8"):
                pass


REPLACE_STATE = os.path.expanduser("~/.local/state/miniply/neu-geladen.json")
# Ab hier stammt eine Datei schon vom neuen Weg (AAC mit 256 kbit/s).
NEW_BITRATE = 200_000
TRASH = ".miniply-papierkorb"


def file_tags(path):
    """Tags, Länge und Bitrate einer vorhandenen Datei."""
    result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration,bit_rate:format_tags",
                             "-of", "json", path], capture_output=True, text=True, check=False)
    try:
        info = json.loads(result.stdout or "{}").get("format", {})
    except ValueError:
        info = {}
    tags = {name.lower(): value for name, value in (info.get("tags") or {}).items()}
    return tags, float(info.get("duration") or 0), int(info.get("bit_rate") or 0)


def catalog_song(artist, title, album):
    """Der Katalogeintrag eines vorhandenen Songs, am liebsten vom selben Album:
    Er liefert die echte Länge und ob es eine unzensierte Fassung gibt."""
    bare = re.sub(r"\s*[\(\[]\s*(feat|ft)\b[^)\]]*[\)\]]", "", title, flags=re.IGNORECASE)
    names = [key(name) for name in split_names(artist)]
    hits = [song for song in itunes(f"{artist} {bare}", "song")
            if song_key(song.get("trackName", "")) == song_key(title)
            and any(name in key(song.get("artistName", "")) for name in names)]
    if not hits:
        return None
    return min(hits, key=lambda s: (key(plain_album(s.get("collectionName", ""))) != key(album),
                                    s.get("trackExplicitness") == "cleaned"))


def to_trash(path, root):
    """Wie der Server: <Wurzel>/.miniply-papierkorb/<Zeit>-<UUID>/<Pfad>, nach 14 Tagen weg.
    Eine harte Verknüpfung, damit der Song bis zum Ersetzen nie fehlt."""
    import uuid
    target = os.path.join(root, TRASH, f"{int(time.time())}-{uuid.uuid4()}", os.path.relpath(path, root))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    try:
        os.link(path, target)
    except OSError:
        shutil.copy2(path, target)
    return target


def replace_song(path, root, testlauf):
    """Lädt einen vorhandenen Song neu und ersetzt ihn unter demselben Namen, damit Lieblingssongs,
    Playlists und Wiedergabezahlen bleiben. Gibt das Ergebnis als kurzen Text zurück."""
    tags, _, bitrate = file_tags(path)
    title, album = tags.get("title"), tags.get("album", "")
    artist = tags.get("album_artist") or tags.get("artist")
    if not title or not artist:
        return "übersprungen: keine Tags"
    if bitrate >= NEW_BITRATE or probe(path, "stream=codec_name") == "opus":
        return "übersprungen: schon neu geladen"
    song = catalog_song(artist, title, album)
    if not song or not song.get("trackTimeMillis"):
        return "übersprungen: nicht im Katalog"
    seconds = song["trackTimeMillis"] // 1000
    needs_uncensored = uncensored(song)
    # Beim Ersetzen nie eine zensierte Fassung: Die alte Datei ist oft unzensiert.
    sources = find_on_youtube(artist, title, seconds, album, needs_uncensored, False)
    if not sources:
        return ("übersprungen: keine als unzensiert markierte Quelle" if needs_uncensored
                else "übersprungen: keine sichere Quelle")
    if testlauf:
        video = sources[0]
        return (f'Testlauf: würde ersetzt durch {video["id"]} ({video.get("album") or video.get("channel", "")}, '
                f'{"unzensiert" if video.get("explicit") else "ohne Markierung"})')
    work = tempfile.mkdtemp(dir=os.path.dirname(path), prefix=".lade-")
    try:
        sound = None
        for video in sources:
            sound = download_audio(video["id"], work, seconds, title)
            if sound:
                break
        if not sound:
            return "fehlgeschlagen: kein Download hat die Prüfung bestanden"
        # Tags vom alten Song, Ton vom neuen.
        fresh = os.path.join(work, "neu.m4a")
        result = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", sound, "-i", path, "-map", "0:a",
                                 "-c", "copy", "-map_metadata", "1", *MP4, fresh], check=False)
        if result.returncode != 0:
            return "fehlgeschlagen: Tags nicht übernommen"
        os.chmod(fresh, 0o664)
        to_trash(path, root)
        os.replace(fresh, path)
        return "neu geladen"
    except (subprocess.TimeoutExpired, OSError) as error:
        return f"fehlgeschlagen: {error}"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def songs_in(paths):
    found = []
    for path in paths:
        if os.path.isfile(path):
            found.append(path)
            continue
        for base, folders, files in os.walk(path):
            folders[:] = sorted(f for f in folders if not f.startswith("."))
            found += [os.path.join(base, f) for f in sorted(files) if not f.startswith(".")
                      and f.lower().endswith(".m4a")]
    return found


def replace_all(paths, root, testlauf):
    """Lädt alle Songs unter `paths` neu. Was schon ersetzt ist, merkt sich eine Datei:
    Ein abgebrochener Lauf macht beim nächsten Song weiter."""
    root = os.path.abspath(root)
    try:
        with open(REPLACE_STATE, encoding="utf-8") as file:
            done = json.load(file)
    except (OSError, ValueError):
        done = {}
    songs = songs_in(paths)
    counts = {}
    for number, path in enumerate(songs, 1):
        relative = os.path.relpath(os.path.abspath(path), root)
        if done.get(relative) == "neu geladen":
            outcome = "übersprungen: schon neu geladen"
        else:
            try:
                outcome = replace_song(path, root, testlauf)
            except (OSError, ValueError, KeyError) as error:
                outcome = f"fehlgeschlagen: {error}"
            if not testlauf:
                done[relative] = outcome
                os.makedirs(os.path.dirname(REPLACE_STATE), exist_ok=True)
                write_json(REPLACE_STATE, done)
        kind = outcome.split(":")[0]
        counts[kind] = counts.get(kind, 0) + 1
        print(f"[{number}/{len(songs)}] {relative}: {outcome}", flush=True)
    print("Fertig: " + ", ".join(f"{count} {kind}" for kind, count in sorted(counts.items())), flush=True)
    return 0


def main():
    os.environ["PATH"] = "/opt/homebrew/bin:" + os.environ.get("PATH", "")
    parser = argparse.ArgumentParser(description="Album oder Song per Name suchen und auf den Pi laden.")
    parser.add_argument("name", nargs="?", help='zum Beispiel "Linkin Park Hybrid Theory"')
    parser.add_argument("-s", "--song", action="store_true", help="nur einen Song statt eines Albums")
    parser.add_argument("-n", "--testlauf", action="store_true", help="nur anzeigen, nichts laden")
    parser.add_argument("-o", "--ordner", help='eigener Ordnername statt "Künstler - Album"')
    parser.add_argument("--dienst", metavar="ORDNER", help="Aufträge aus diesem Ordner dauerhaft abarbeiten")
    parser.add_argument("--neu-laden", nargs="+", metavar="PFAD",
                        help="vorhandene Songs (Ordner oder Dateien auf dem Pi) neu laden und ersetzen")
    parser.add_argument("--wurzel", default="/mnt/media", help="Mediathek mit dem Papierkorb, für --neu-laden")
    args = parser.parse_args()

    if args.neu_laden:
        return replace_all(args.neu_laden, args.wurzel, args.testlauf)

    if args.dienst:
        # Der Dienst braucht das API-Token nicht, und yt-dlp soll es nicht erben.
        os.environ.pop("MINIPLY_TOKEN", None)
        genius_token()
        serve(args.dienst, TARGET)
        return 0
    if not args.name:
        parser.error("Name fehlt")
    plan = plan_song(args.name) if args.song else plan_album(args.name)
    if not plan or not plan["titles"]:
        print(f"Nichts gefunden für: {args.name}", file=sys.stderr)
        return 1
    print(f'{plan["artist"]} - {plan["album"]}: {len(plan["titles"])} Song(s), Liste von {plan["source"]}')

    folder_name = safe_name(args.ordner or f'{plan["artist"]} - {plan["album"]}')
    base = tempfile.mkdtemp(prefix="musik-suchen.")
    try:
        folder = os.path.join(base, folder_name)
        os.makedirs(folder)
        missing, loaded = [], 0
        for number, track in enumerate(plan["titles"], 1):
            if args.testlauf:
                sources = find_on_youtube(plan["artist"], track["title"], track.get("seconds"), plan["album"],
                                          track.get("uncensored", False))
                if not sources:
                    print(f'{number:2d}. {track["title"]}: nicht sicher gefunden, würde ausgelassen')
                    missing.append(track["title"])
                    continue
                video = sources[0]
                print(f'{number:2d}. {credited_title(track)} <- {video["id"]} {video.get("title")} '
                      f'({video.get("artist") or video.get("channel")}, {video.get("album", "")}, '
                      f'{"unzensiert" if video.get("explicit") else "ohne Markierung"})')
                continue
            if load_track(plan, track, folder, number, number):
                loaded += 1
            else:
                missing.append(track["title"])
        if args.testlauf:
            print("Testlauf: nichts geladen.")
            return 0
        if loaded:
            save_cover(plan["cover"], folder)
            subprocess.run(["chmod", "-R", "ug=rwX,o=rX", base], check=True)
            # Ohne -p: Die Rechte des Musik-Ordners bleiben, wie sie sind.
            subprocess.run(["rsync", "-rt", "--partial", folder, TARGET], check=True)
            print(f"Fertig: {loaded} Song(s) liegen in {TARGET}{folder_name}")
        if missing:
            print("Nicht geladen: " + ", ".join(missing), file=sys.stderr)
            return 1
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
