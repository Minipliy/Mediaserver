//! Path-based library structure: folder albums, cover images, series,
//! seasons and episode numbers. Pure functions over the scanned catalog;
//! nothing here touches the file system or the network.

use crate::catalog::{Catalog, SubtitleRef};
use std::collections::HashMap;

const IMAGE_EXTENSIONS: [&str; 7] = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif"];
const COVER_NAMES: [&str; 10] = [
    "cover",
    "folder",
    "front",
    "album",
    "albumart",
    "poster",
    "artwork",
    "thumb",
    "thumbnail",
    "season",
];
const MUSIC_ROOTS: [&str; 2] = ["musik", "music"];
const SERIES_ROOTS: [&str; 5] = ["serien", "series", "tv shows", "tv-serien", "tvshows"];

pub(crate) fn is_subtitle(path: &str) -> bool {
    extension(path).is_some_and(|ext| ext == "srt" || ext == "vtt")
}

pub(crate) fn is_lyrics(path: &str) -> bool {
    extension(path).is_some_and(|ext| ext == "lrc" || ext == "txt")
}

fn language_label(code: &str) -> Option<&'static str> {
    Some(match code {
        "de" | "ger" | "deu" | "german" | "deutsch" => "Deutsch",
        "en" | "eng" | "english" | "englisch" => "Englisch",
        "fr" | "fre" | "fra" | "french" => "Französisch",
        "es" | "spa" | "spanish" => "Spanisch",
        "it" | "ita" | "italian" => "Italienisch",
        "nl" | "dut" | "nld" | "dutch" => "Niederländisch",
        "pl" | "pol" | "polish" => "Polnisch",
        "tr" | "tur" | "turkish" => "Türkisch",
        "ru" | "rus" | "russian" => "Russisch",
        "pt" | "por" | "portuguese" => "Portugiesisch",
        "ja" | "jpn" | "japanese" => "Japanisch",
        _ => return None,
    })
}

fn language_code(code: &str) -> &str {
    match code {
        "ger" | "deu" | "german" | "deutsch" => "de",
        "eng" | "english" | "englisch" => "en",
        "fre" | "fra" | "french" => "fr",
        "spa" | "spanish" => "es",
        "ita" | "italian" => "it",
        "dut" | "nld" | "dutch" => "nl",
        "pol" | "polish" => "pl",
        "tur" | "turkish" => "tr",
        "rus" | "russian" => "ru",
        "por" | "portuguese" => "pt",
        "jpn" | "japanese" => "ja",
        other => other,
    }
}

/// `Film.de.forced.srt` next to `Film.mp4` -> language "de", forced.
fn subtitle_ref(video_stem: &str, name: &str, id: &str) -> Option<SubtitleRef> {
    let file_stem = stem(name);
    let rest = if file_stem.eq_ignore_ascii_case(video_stem) {
        ""
    } else {
        let prefix = file_stem.get(..video_stem.len())?;
        if !prefix.eq_ignore_ascii_case(video_stem) {
            return None;
        }
        file_stem[video_stem.len()..].strip_prefix(['.', '_', '-', ' '])?
    };
    let mut language = None;
    let mut label = None;
    let mut forced = false;
    for part in rest.split(['.', '_', '-', ' ']).filter(|p| !p.is_empty()) {
        let lower = part.to_lowercase();
        if lower == "forced" {
            forced = true;
        } else if let Some(name) = language_label(&lower) {
            language = Some(language_code(&lower).to_owned());
            label = Some(name.to_owned());
        }
    }
    let mut label = label.unwrap_or_else(|| {
        if rest.is_empty() {
            "Untertitel".to_owned()
        } else {
            crate::text::clean(rest)
        }
    });
    if forced {
        label.push_str(" (erzwungen)");
    }
    Some(SubtitleRef {
        id: id.to_owned(),
        language,
        label,
        forced,
    })
}

/// Position of a "feat." marker (case-insensitive, as a whole word).
fn feat_marker(value: &str) -> Option<(usize, usize)> {
    let lower = value.to_lowercase();
    if lower.len() != value.len() {
        // Lower-casing changed byte offsets (rare characters): search ASCII-only.
        return feat_marker_ascii(value);
    }
    for marker in ["featuring ", "feat. ", "feat ", "ft. ", "ft "] {
        let mut start = 0;
        while let Some(found) = lower[start..].find(marker) {
            let at = start + found;
            let before = lower[..at].chars().last();
            if before.is_none_or(|c| c == ' ' || c == '(' || c == '[') {
                return Some((at, at + marker.len()));
            }
            start = at + marker.len();
        }
    }
    None
}

fn feat_marker_ascii(value: &str) -> Option<(usize, usize)> {
    let lower = value.to_ascii_lowercase();
    for marker in ["featuring ", "feat. ", "feat ", "ft. ", "ft "] {
        let mut start = 0;
        while let Some(found) = lower[start..].find(marker) {
            let at = start + found;
            let before = lower[..at].chars().last();
            if before.is_none_or(|c| c == ' ' || c == '(' || c == '[') {
                return Some((at, at + marker.len()));
            }
            start = at + marker.len();
        }
    }
    None
}

/// "A & B, C" -> [A, B, C] (only used for the part after "feat.").
fn split_guests(value: &str) -> Vec<String> {
    value
        .split([',', ';', '&', '/'])
        .flat_map(|part| part.split(" and ").flat_map(|p| p.split(" x ")))
        .map(|p| {
            p.trim()
                .trim_matches(|c| c == '(' || c == ')' || c == '[' || c == ']')
                .trim()
                .to_owned()
        })
        .filter(|p| !p.is_empty())
        .collect()
}

/// "Soli & Domitiana" is Soli featuring Domitiana: the first name is the
/// artist, every further one a guest, so no artist "Soli & Domitiana" appears.
fn split_duo(name: &str) -> (Option<String>, Vec<String>) {
    let mut names = name
        .split('&')
        .map(str::trim)
        .filter(|part| !part.is_empty());
    let main = names.next().map(str::to_owned);
    (main, names.map(str::to_owned).collect())
}

/// Main artist, guests and a title without "(feat. …)".
/// "Eminem feat. Rihanna" / "Love The Way You Lie (feat. Rihanna)".
pub fn credits(artist: Option<&str>, title: &str) -> (Option<String>, Vec<String>, String) {
    let mut guests: Vec<String> = Vec::new();
    let mut main = None;
    if let Some(artist) = artist {
        let mut parts = artist.split(';').map(str::trim).filter(|p| !p.is_empty());
        let first = parts.next().unwrap_or("");
        let (head, tail) = match feat_marker(first) {
            Some((at, end)) => (
                first[..at].trim_end_matches([' ', '(', '[']),
                Some(&first[end..]),
            ),
            None => (first, None),
        };
        let (first, more) = split_duo(head);
        main = first;
        guests.extend(more);
        if let Some(tail) = tail {
            guests.extend(split_guests(tail));
        }
        guests.extend(parts.map(str::to_owned));
    }
    let mut clean_title = title.to_owned();
    if let Some((at, end)) = feat_marker(title) {
        let opener = title[..at].chars().last();
        let rest = &title[end..];
        let (inside, after) = match opener {
            Some('(') => rest.split_once(')').unwrap_or((rest, "")),
            Some('[') => rest.split_once(']').unwrap_or((rest, "")),
            _ => (rest, ""),
        };
        guests.extend(split_guests(inside));
        let head = title[..at].trim_end_matches(['(', '[', ' ', '-']);
        clean_title = format!("{head}{after}").trim().to_owned();
        if clean_title.is_empty() {
            clean_title = title.to_owned();
        }
    }
    let mut seen = std::collections::HashSet::new();
    let main_key = main.as_deref().map(name_key);
    guests.retain(|g| {
        let key = name_key(g);
        Some(&key) != main_key.as_ref() && seen.insert(if key.is_empty() { g.clone() } else { key })
    });
    (main, guests, clean_title)
}

/// Title and guests of "Artist - Title", common in file names and video titles:
/// "DRAKE FT. LOE SHIMMY - I'M SPENT" / "Drake, Don Toliver - Solar Eclipse".
/// None unless the part before the dash starts with the known artist.
fn strip_artist_prefix(title: &str, artist: &str) -> Option<(String, Vec<String>)> {
    let (head, tail) = [" - ", " – ", " — "]
        .iter()
        .find_map(|sep| title.split_once(sep))?;
    let tail = tail.split_whitespace().collect::<Vec<_>>().join(" ");
    if tail.is_empty() {
        return None;
    }
    let (names, feat) = match feat_marker(head) {
        Some((at, end)) => (head[..at].trim_end_matches([' ', '(', '[']), &head[end..]),
        None => (head, ""),
    };
    let mut guests = Vec::new();
    if !same_name(names, artist) {
        let mut listed = split_guests(names).into_iter();
        if !same_name(&listed.next()?, artist) {
            return None;
        }
        guests.extend(listed);
    }
    guests.extend(split_guests(feat));
    Some((tail, guests))
}

/// Comparable form of a name: "André 3000", "Andre 3000" and a decomposed "André"
/// (e plus combining accent, as some tags store it) are the same artist.
fn name_key(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' => 'a',
            'ç' | 'ć' | 'č' => 'c',
            'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' => 'e',
            'ì' | 'í' | 'î' | 'ï' | 'ī' => 'i',
            'ñ' | 'ń' => 'n',
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' => 'o',
            'ù' | 'ú' | 'û' | 'ü' | 'ū' => 'u',
            'ý' | 'ÿ' => 'y',
            'ś' | 'š' => 's',
            'ź' | 'ż' | 'ž' => 'z',
            'ł' => 'l',
            other => other,
        })
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn same_name(a: &str, b: &str) -> bool {
    let key = name_key(a);
    !key.is_empty() && key == name_key(b)
}

/// "YEAT - Luh Leakyz Vol. 1" -> (Some("YEAT"), "Luh Leakyz Vol. 1"),
/// "2001 - Hybrid Theory" -> (None, "Hybrid Theory").
/// Split only if the first part is the known artist, a year, or (without any
/// artist information) whenever the folder looks like "Artist - Album".
pub fn split_album_folder(name: &str, artist: Option<&str>) -> (Option<String>, String) {
    let separator = [" - ", " – ", " — "]
        .iter()
        .find_map(|sep| name.split_once(sep));
    let Some((head, tail)) = separator else {
        return (None, name.to_owned());
    };
    let (head, tail) = (head.trim(), tail.trim());
    if tail.is_empty() || head.is_empty() {
        return (None, name.to_owned());
    }
    if head.len() == 4 && head.chars().all(|c| c.is_ascii_digit()) {
        return (None, tail.to_owned());
    }
    match artist {
        Some(known) if same_name(head, known) => (Some(head.to_owned()), tail.to_owned()),
        Some(_) => (None, name.to_owned()),
        None => (Some(head.to_owned()), tail.to_owned()),
    }
}

/// Title from a file name without tags: "01 - Papercut" -> (Some(1), "Papercut"),
/// "YEAT - Countup" (artist YEAT) -> (None, "Countup").
pub fn clean_file_title(title: &str, artist: Option<&str>) -> (Option<u32>, String) {
    let mut rest = title.trim();
    let mut number = None;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !digits.is_empty() && digits.len() <= 3 {
        let remainder = &rest[digits.len()..];
        let separated = remainder
            .trim_start()
            .starts_with(['.', '-', '_', ')', '–']);
        let leading_zero =
            digits.len() >= 2 && digits.starts_with('0') && remainder.starts_with(' ');
        let after = remainder
            .trim_start_matches([' ', '.', '-', '_', ')', '–'])
            .trim();
        if (separated || leading_zero) && !after.is_empty() {
            number = digits.parse().ok();
            rest = after;
        }
    }
    if let Some(artist) = artist
        && let Some((head, tail)) = rest.split_once(" - ")
        && same_name(head, artist)
        && !tail.trim().is_empty()
    {
        rest = tail.trim();
    }
    (number, rest.to_owned())
}

pub(crate) fn is_image(path: &str) -> bool {
    extension(path).is_some_and(|ext| IMAGE_EXTENSIONS.contains(&ext.as_str()))
}

fn extension(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
}

fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(dir, _)| dir)
}

fn last_component(path: &str) -> &str {
    path.rsplit_once('/').map_or(path, |(_, name)| name)
}

fn stem(name: &str) -> &str {
    name.rsplit_once('.')
        .map_or(name, |(stem, _)| stem)
        .trim_end_matches(' ')
}

fn is_root_named(dir: &str, names: &[&str]) -> bool {
    !dir.contains('/') && names.contains(&dir.to_lowercase().as_str())
}

/// Lower-case alphanumeric words. "Staffel_03" -> ["staffel", "03"].
fn tokens(value: &str) -> Vec<String> {
    let lower = value.to_lowercase();
    lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(str::to_owned)
        .collect()
}

fn digits_only(token: &str) -> Option<u32> {
    if !token.is_empty() && token.len() <= 4 && token.chars().all(|c| c.is_ascii_digit()) {
        token.parse().ok()
    } else {
        None
    }
}

/// `prefix` immediately followed by digits, e.g. "season3", "s03", "cd2".
fn prefixed_number(token: &str, prefix: &str) -> Option<u32> {
    digits_only(token.strip_prefix(prefix)?)
}

/// Season number from a folder name: "Season 1", "Staffel 01", "S12",
/// "3. Staffel", "Two and a Half Men - Season 4", "Specials" (0), "4".
pub fn parse_season(name: &str) -> Option<u32> {
    let words = tokens(name);
    if words.len() == 1 {
        if let Some(number) = digits_only(&words[0]) {
            return Some(number);
        }
        if ["specials", "special"].contains(&words[0].as_str()) {
            return Some(0);
        }
    }
    const WORDS: [&str; 6] = [
        "season",
        "staffel",
        "series",
        "saison",
        "temporada",
        "stagione",
    ];
    for (index, word) in words.iter().enumerate() {
        if WORDS.contains(&word.as_str()) {
            if let Some(number) = words.get(index + 1).and_then(|w| digits_only(w)) {
                return Some(number);
            }
            // "3. Staffel" / "3rd Season"
            if index > 0 {
                let previous = words[index - 1].trim_end_matches(|c: char| c.is_alphabetic());
                if let Some(number) = digits_only(previous) {
                    return Some(number);
                }
            }
        }
        for prefix in WORDS.iter().copied().chain(["s"]) {
            if let Some(number) = prefixed_number(word, prefix) {
                return Some(number);
            }
        }
    }
    None
}

/// "s01e02", "S1E2E3" -> (1, 2)
fn season_episode_token(token: &str) -> Option<(u32, u32)> {
    let rest = token.strip_prefix('s')?;
    let season: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    let rest = rest[season.len()..].strip_prefix('e')?;
    let episode: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    Some((digits_only(&season)?, digits_only(&episode)?))
}

/// "1x02" -> (1, 2); rejects resolutions such as "1920x1080".
fn cross_token(token: &str) -> Option<(u32, u32)> {
    let (season, episode) = token.split_once('x')?;
    if season.len() > 2 || episode.is_empty() || episode.len() > 3 {
        return None;
    }
    Some((digits_only(season)?, digits_only(episode)?))
}

/// Season (if the name carries one) and episode number from a file name.
pub fn parse_episode(file_stem: &str) -> (Option<u32>, Option<u32>) {
    let words = tokens(file_stem);
    for word in &words {
        if let Some((season, episode)) = season_episode_token(word).or_else(|| cross_token(word)) {
            return (Some(season), Some(episode));
        }
    }
    for (index, word) in words.iter().enumerate() {
        if ["episode", "folge", "ep", "teil", "part"].contains(&word.as_str())
            && let Some(number) = words.get(index + 1).and_then(|w| digits_only(w))
        {
            return (None, Some(number));
        }
        for prefix in ["episode", "folge", "ep", "e"] {
            if let Some(number) = prefixed_number(word, prefix) {
                return (None, Some(number));
            }
        }
    }
    // "01 - Pilot"
    if file_stem
        .trim_start()
        .starts_with(|c: char| c.is_ascii_digit())
        && let Some(number) = words.first().and_then(|w| digits_only(w))
        && number < 1000
    {
        return (None, Some(number));
    }
    (None, None)
}

/// Disc folders inside an album: "CD1", "CD 2", "Disc 1", "Disk02".
fn parse_disc(name: &str) -> Option<u32> {
    let words = tokens(name);
    match words.as_slice() {
        [word] => ["cd", "disc", "disk"]
            .iter()
            .find_map(|prefix| prefixed_number(word, prefix)),
        [word, number] if ["cd", "disc", "disk"].contains(&word.as_str()) => digits_only(number),
        _ => None,
    }
}

fn cover_rank(name: &str) -> usize {
    let lower = stem(name).to_lowercase();
    COVER_NAMES
        .iter()
        .position(|candidate| lower == *candidate || lower.starts_with(&format!("{candidate} ")))
        .unwrap_or(COVER_NAMES.len())
}

/// Fill derived fields of every media item and the per-directory cover map.
pub fn organize(catalog: &mut Catalog) {
    // Best image per directory and images by (directory, stem).
    let mut best: HashMap<String, (usize, String, String)> = HashMap::new();
    let mut by_stem: HashMap<(String, String), String> = HashMap::new();
    for media in catalog.files.values() {
        if media.kind != "file" || !is_image(&media.path) {
            continue;
        }
        let dir = parent(&media.path).to_owned();
        by_stem.insert(
            (dir.clone(), stem(&media.name).to_lowercase()),
            media.id.clone(),
        );
        let candidate = (
            cover_rank(&media.name),
            media.name.to_lowercase(),
            media.id.clone(),
        );
        match best.get(&dir) {
            Some(current) if (current.0, &current.1) <= (candidate.0, &candidate.1) => {}
            _ => {
                best.insert(dir, candidate);
            }
        }
    }
    let mut covers: HashMap<String, String> = best
        .into_iter()
        .map(|(dir, (_, _, id))| (dir, id))
        .collect();

    // Pass 1: albums and series derived from the path only.
    for media in catalog.files.values_mut() {
        media.album_key = None;
        media.album_artist = None;
        media.cover_id = None;
        media.series_key = None;
        media.season_folder = None;
        media.season = None;
        media.episode = None;
        media.subtitles = Vec::new();
        media.has_lyrics = false;
        match media.kind.as_str() {
            "audio" => {
                let title = match &media.tag_title {
                    Some(tag) => tag.clone(),
                    None => {
                        let (number, title) =
                            clean_file_title(&media.file_title, media.tag_artist.as_deref());
                        if media.track_number.is_none() {
                            media.track_number = number;
                        }
                        title
                    }
                };
                media.album = media.tag_album.clone();
                let mut dir = parent(&media.path).to_owned();
                if let Some(disc) = parse_disc(last_component(&dir)) {
                    if media.disc_number.is_none() {
                        media.disc_number = Some(disc);
                    }
                    dir = parent(&dir).to_owned();
                }
                let tag_artist = credits(media.tag_artist.as_deref(), "").0;
                let mut folder_artist = None;
                if !dir.is_empty() && !is_root_named(&dir, &MUSIC_ROOTS) {
                    let folder = crate::text::clean(last_component(&dir));
                    // Artist information for "Artist - Album" folders: tags,
                    // else the parent folder (unless it is the music root).
                    let grandparent = parent(&dir);
                    let parent_artist = (!grandparent.is_empty()
                        && !is_root_named(grandparent, &MUSIC_ROOTS))
                    .then(|| crate::text::clean(last_component(grandparent)));
                    let known = tag_artist.clone().or(parent_artist);
                    let (artist, album) = split_album_folder(&folder, known.as_deref());
                    folder_artist = artist;
                    media.album = Some(album);
                    media.album_key = Some(dir);
                }
                let (title, title_guests) = tag_artist
                    .as_deref()
                    .or(folder_artist.as_deref())
                    .and_then(|artist| strip_artist_prefix(&title, artist))
                    .unwrap_or((title, Vec::new()));
                let (main, mut featured, clean_title) =
                    credits(media.tag_artist.as_deref(), &title);
                for guest in title_guests.into_iter().rev() {
                    if !featured.iter().any(|g| same_name(g, &guest)) {
                        featured.insert(0, guest);
                    }
                }
                media.artist = match main {
                    Some(main) => Some(main),
                    None => folder_artist.and_then(|folder| {
                        let (first, more) = split_duo(&folder);
                        featured.extend(more);
                        first
                    }),
                };
                media.featured = featured;
                media.title = clean_title;
            }
            "video" => {
                let parts: Vec<&str> = media.path.split('/').collect();
                let Some(index) = parts
                    .iter()
                    .position(|p| SERIES_ROOTS.contains(&p.to_lowercase().as_str()))
                else {
                    continue;
                };
                if index + 2 >= parts.len() {
                    continue;
                }
                media.series_key = Some(parts[..=index + 1].join("/"));
                let (file_season, episode) = parse_episode(stem(&media.name));
                media.episode = episode;
                if index + 3 < parts.len() {
                    let folder = parts[index + 2];
                    media.season_folder = Some(folder.to_owned());
                    media.season = parse_season(folder).or(file_season);
                } else {
                    media.season = file_season;
                }
            }
            _ => {}
        }
    }

    // Pass 2: album artist (most common tag artist, else the parent folder).
    let mut artists: HashMap<String, HashMap<String, usize>> = HashMap::new();
    let mut embedded: HashMap<String, String> = HashMap::new();
    for media in catalog.files.values() {
        if let Some(key) = &media.album_key {
            if let Some(artist) = &media.tag_artist {
                *artists
                    .entry(key.clone())
                    .or_default()
                    .entry(artist.clone())
                    .or_default() += 1;
            }
            if media.embedded_art {
                let current = embedded
                    .entry(key.clone())
                    .or_insert_with(|| media.id.clone());
                if media.id < *current {
                    *current = media.id.clone();
                }
            }
        }
    }
    let album_artist = |key: &str| -> Option<String> {
        if let Some(counts) = artists.get(key) {
            return counts
                .iter()
                .max_by(|a, b| a.1.cmp(b.1).then_with(|| b.0.cmp(a.0)))
                .map(|(name, _)| name.clone());
        }
        let grandparent = parent(key);
        if !grandparent.is_empty() && !is_root_named(grandparent, &MUSIC_ROOTS) {
            return Some(crate::text::clean(last_component(grandparent)));
        }
        // "Musik/Artist - Album" without tags.
        split_album_folder(&crate::text::clean(last_component(key)), None).0
    };
    let mut album_artists: HashMap<String, Option<String>> = HashMap::new();
    for media in catalog.files.values() {
        if let Some(key) = &media.album_key {
            album_artists
                .entry(key.clone())
                .or_insert_with(|| album_artist(key));
        }
    }
    // Album covers: folder image, else an image in a disc folder, else
    // embedded artwork of one of its tracks.
    for (key, track) in &embedded {
        covers.entry(key.clone()).or_insert_with(|| track.clone());
    }
    for media in catalog.files.values() {
        if let Some(key) = &media.album_key
            && !covers.contains_key(key)
            && let Some(image) = covers.get(parent(&media.path)).cloned()
        {
            covers.insert(key.clone(), image);
        }
    }

    // Subtitles and lyrics files by directory.
    let mut extras: HashMap<String, Vec<(String, String)>> = HashMap::new();
    for media in catalog.files.values() {
        if media.kind == "file" && (is_subtitle(&media.path) || is_lyrics(&media.path)) {
            extras
                .entry(parent(&media.path).to_owned())
                .or_default()
                .push((media.name.clone(), media.id.clone()));
        }
    }

    // Pass 3: per item cover and album artist.
    for media in catalog.files.values_mut() {
        let dir = parent(&media.path).to_owned();
        let same_stem = by_stem
            .get(&(dir.clone(), stem(&media.name).to_lowercase()))
            .filter(|id| **id != media.id)
            .cloned();
        let siblings = extras.get(&dir);
        match media.kind.as_str() {
            "video" => {
                let video_stem = stem(&media.name).to_owned();
                let mut subtitles: Vec<SubtitleRef> = siblings
                    .into_iter()
                    .flatten()
                    .filter(|(name, _)| is_subtitle(name))
                    .filter_map(|(name, id)| subtitle_ref(&video_stem, name, id))
                    .collect();
                subtitles.sort_by(|a, b| (a.forced, &a.label).cmp(&(b.forced, &b.label)));
                media.subtitles = subtitles;
            }
            "audio" => {
                let track_stem = stem(&media.name).to_lowercase();
                media.has_lyrics = media.embedded_lyrics
                    || siblings.into_iter().flatten().any(|(name, _)| {
                        extension(name).as_deref() == Some("lrc")
                            && stem(name).to_lowercase() == track_stem
                    });
            }
            _ => {}
        }
        match media.kind.as_str() {
            "audio" => {
                if let Some(key) = media.album_key.clone() {
                    media.album_artist = album_artists.get(&key).cloned().flatten();
                    if media.artist.is_none() {
                        media.artist = media.album_artist.clone();
                    }
                    media.cover_id = covers.get(&key).cloned();
                }
                media.artist_credit = match (&media.artist, media.featured.is_empty()) {
                    (Some(artist), false) => {
                        Some(format!("{artist} feat. {}", media.featured.join(", ")))
                    }
                    _ => None,
                };
                if media.cover_id.is_none() {
                    media.cover_id =
                        same_stem.or_else(|| media.embedded_art.then(|| media.id.clone()));
                }
            }
            "video" => {
                media.cover_id = same_stem
                    .or_else(|| {
                        (!dir.is_empty() && dir.contains('/'))
                            .then(|| covers.get(&dir).cloned())
                            .flatten()
                    })
                    .or_else(|| {
                        media
                            .series_key
                            .as_ref()
                            .and_then(|key| covers.get(key).cloned())
                    });
            }
            _ => {}
        }
    }
    catalog.covers = covers;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seasons_from_folder_names() {
        for (name, expected) in [
            ("Season 1", Some(1)),
            ("Season 12", Some(12)),
            ("Staffel 04", Some(4)),
            ("staffel_6", Some(6)),
            ("S02", Some(2)),
            ("Season03", Some(3)),
            ("3. Staffel", Some(3)),
            ("Two and a Half Men - Season 7", Some(7)),
            ("Specials", Some(0)),
            ("5", Some(5)),
            ("Extras", None),
            ("Bonusmaterial", None),
        ] {
            assert_eq!(parse_season(name), expected, "{name}");
        }
    }

    #[test]
    fn episodes_from_file_names() {
        for (name, expected) in [
            ("S01E02 - Pilot", (Some(1), Some(2))),
            ("Two.and.a.Half.Men.S03E14.720p.WEB", (Some(3), Some(14))),
            ("two_and_a_half_men_1x05", (Some(1), Some(5))),
            ("Folge 7", (None, Some(7))),
            ("Episode 12 - Finale", (None, Some(12))),
            ("E09", (None, Some(9))),
            ("03 - Der Anfang", (None, Some(3))),
            ("Film 1920x1080", (None, None)),
            ("Pilot", (None, None)),
        ] {
            assert_eq!(parse_episode(name), expected, "{name}");
        }
    }

    #[test]
    fn subtitle_names() {
        let s = subtitle_ref("Film", "Film.de.srt", "x").unwrap();
        assert_eq!(
            (s.language.as_deref(), s.label.as_str(), s.forced),
            (Some("de"), "Deutsch", false)
        );
        let s = subtitle_ref("Film", "Film.eng.forced.srt", "x").unwrap();
        assert_eq!(
            (s.language.as_deref(), s.label.as_str(), s.forced),
            (Some("en"), "Englisch (erzwungen)", true)
        );
        assert_eq!(
            subtitle_ref("Film", "Film.srt", "x").unwrap().label,
            "Untertitel"
        );
        assert!(subtitle_ref("Film", "Filmmusik.srt", "x").is_none());
        assert!(subtitle_ref("Film 2", "Film.srt", "x").is_none());
    }

    #[test]
    fn featured_artists() {
        let (main, guests, title) = credits(Some("Eminem feat. Rihanna"), "Love The Way You Lie");
        assert_eq!(main.as_deref(), Some("Eminem"));
        assert_eq!(guests, vec!["Rihanna".to_owned()]);
        assert_eq!(title, "Love The Way You Lie");
        let (main, guests, title) = credits(
            Some("Calvin Harris"),
            "This Is What You Came For (feat. Rihanna & Drake)",
        );
        assert_eq!(main.as_deref(), Some("Calvin Harris"));
        assert_eq!(guests, vec!["Rihanna".to_owned(), "Drake".to_owned()]);
        assert_eq!(title, "This Is What You Came For");
        // With "&" the first name is the artist and the others are guests.
        let (main, guests, _) = credits(Some("Soli & Domitiana"), "Lied");
        assert_eq!(main.as_deref(), Some("Soli"));
        assert_eq!(guests, vec!["Domitiana".to_owned()]);
        let (main, guests, _) = credits(Some("Soli & Domitiana feat. Ufo361"), "Lied");
        assert_eq!(main.as_deref(), Some("Soli"));
        assert_eq!(guests, vec!["Domitiana".to_owned(), "Ufo361".to_owned()]);
        let (main, guests, _) = credits(Some("Simon & Garfunkel"), "The Boxer");
        assert_eq!((main.as_deref(), guests.len()), (Some("Simon"), 1));
        let (main, guests, _) = credits(Some("Daft Punk; Pharrell Williams"), "Get Lucky");
        assert_eq!(main.as_deref(), Some("Daft Punk"));
        assert_eq!(guests, vec!["Pharrell Williams".to_owned()]);
        let (_, guests, title) = credits(Some("Kraftklub"), "Songs für Liam [ft. Casper]");
        assert_eq!(guests, vec!["Casper".to_owned()]);
        assert_eq!(title, "Songs für Liam");
        let (_, guests, title) = credits(Some("Left Boy"), "Soft (Remix)");
        assert_eq!((guests.len(), title.as_str()), (0, "Soft (Remix)"));
        let (_, guests, _) = credits(Some("Ftp Crew"), "Craft");
        assert!(guests.is_empty());
        // The same guest from tag and title, once with a decomposed accent: listed once.
        let (main, guests, title) = credits(
            Some("Drake; Andre\u{301} 3000"),
            "The Real Her (feat. Lil Wayne & André 3000)",
        );
        assert_eq!(
            (main.as_deref(), title.as_str()),
            (Some("Drake"), "The Real Her")
        );
        assert_eq!(guests.len(), 2, "{guests:?}");
        assert!(same_name("Andre 3000", "André 3000"));
    }

    #[test]
    fn artist_album_folders() {
        assert_eq!(
            split_album_folder("YEAT - Luh Leakyz Vol. 1", Some("Yeat")),
            (Some("YEAT".to_owned()), "Luh Leakyz Vol. 1".to_owned())
        );
        assert_eq!(
            split_album_folder("2001 - Hybrid Theory", Some("Linkin Park")),
            (None, "Hybrid Theory".to_owned())
        );
        assert_eq!(
            split_album_folder("Live - Throwing Copper", Some("Live")),
            (Some("Live".to_owned()), "Throwing Copper".to_owned())
        );
        // Known artist differs: the dash is part of the album name.
        assert_eq!(
            split_album_folder("Hits - The Best Of", Some("Queen")),
            (None, "Hits - The Best Of".to_owned())
        );
        assert_eq!(
            split_album_folder("Abbey Road", None),
            (None, "Abbey Road".to_owned())
        );
    }

    #[test]
    fn artist_prefix_in_titles() {
        let strip = |title, artist| strip_artist_prefix(title, artist).unwrap();
        assert_eq!(
            strip("DRAKE -  NEW BESTIE", "Drake"),
            ("NEW BESTIE".to_owned(), vec![])
        );
        assert_eq!(
            strip("DRAKE FT. LOE SHIMMY - I'M SPENT", "Drake"),
            ("I'M SPENT".to_owned(), vec!["LOE SHIMMY".to_owned()])
        );
        assert_eq!(
            strip("Drake, Don Toliver, Yebba - Cold Shoulder", "Drake"),
            (
                "Cold Shoulder".to_owned(),
                vec!["Don Toliver".to_owned(), "Yebba".to_owned()]
            )
        );
        assert_eq!(
            strip("Simon & Garfunkel - The Boxer", "Simon & Garfunkel"),
            ("The Boxer".to_owned(), vec![])
        );
        // The dash belongs to the title when the artist does not match.
        assert_eq!(strip_artist_prefix("Hits - The Best Of", "Queen"), None);
        assert_eq!(strip_artist_prefix("Countup", "YEAT"), None);
    }

    #[test]
    fn titles_from_file_names() {
        assert_eq!(
            clean_file_title("01 - Papercut", None),
            (Some(1), "Papercut".to_owned())
        );
        assert_eq!(
            clean_file_title("07. Numb", None),
            (Some(7), "Numb".to_owned())
        );
        assert_eq!(
            clean_file_title("YEAT - Countup", Some("YEAT")),
            (None, "Countup".to_owned())
        );
        assert_eq!(clean_file_title("2112", None), (None, "2112".to_owned()));
        assert_eq!(
            clean_file_title("99 Luftballons", None),
            (None, "99 Luftballons".to_owned())
        );
        assert_eq!(
            clean_file_title("01 Papercut", None),
            (Some(1), "Papercut".to_owned())
        );
        assert_eq!(
            clean_file_title("3 - Intro", None),
            (Some(3), "Intro".to_owned())
        );
    }

    #[test]
    fn disc_folders() {
        assert_eq!(parse_disc("CD1"), Some(1));
        assert_eq!(parse_disc("Disc 2"), Some(2));
        assert_eq!(parse_disc("Discography"), None);
    }

    #[test]
    fn cover_names_rank_before_other_images() {
        assert!(cover_rank("cover.jpg") < cover_rank("IMG_1234.jpg"));
        assert!(cover_rank("Folder.PNG") < cover_rank("back.png"));
    }
}
