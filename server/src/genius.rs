//! Song texts and album track lists from the public pages of genius.com.
//!
//! With `MINIPLY_GENIUS_TOKEN` (a free client access token) the official API
//! finds songs and album track lists. The API has no song texts, so these come
//! from the song page. Without a token the addresses are derived from artist
//! and title ("Linkin-park-papercut-lyrics"), which finds fewer songs. The
//! robots.txt closes the site's internal `/api`, so that is not used.

use crate::metadata::Entry;
use reqwest::Url;
use serde_json::{Value, json};
use std::collections::HashMap;

const MAX_PAGE_BYTES: usize = 6 * 1024 * 1024;
/// Songs not on the Genius list sort behind those that are.
const UNLISTED_TRACK: u32 = 1000;

/// Network outage, rate limit or server error: not the same as "not found".
pub struct Unavailable;

/// "Don't Stop (Mix) & More" -> "dont-stop-mix-and-more".
fn slug_words(value: &str) -> String {
    let mut slug = String::new();
    for c in value.to_lowercase().chars() {
        match c {
            'ä' | 'á' | 'à' | 'â' | 'ã' | 'å' => slug.push('a'),
            'é' | 'è' | 'ê' | 'ë' => slug.push('e'),
            'í' | 'ì' | 'î' | 'ï' => slug.push('i'),
            'ö' | 'ó' | 'ò' | 'ô' | 'õ' | 'ø' => slug.push('o'),
            'ü' | 'ú' | 'ù' | 'û' => slug.push('u'),
            'ß' => slug.push_str("ss"),
            'ñ' => slug.push('n'),
            'ç' => slug.push('c'),
            '&' => slug.push_str(" and "),
            '\'' | '’' | '‘' | '.' | '"' | '“' | '”' | ',' | '!' | '?' | ':' | ';' => {}
            c if c.is_alphanumeric() => slug.push(c),
            _ => slug.push(' '),
        }
    }
    slug.split_whitespace().collect::<Vec<_>>().join("-")
}

fn capitalized(slug: &str) -> String {
    let mut chars = slug.chars();
    chars.next().map_or_else(String::new, |first| {
        first.to_uppercase().chain(chars).collect()
    })
}

fn page(path: &str) -> Option<Url> {
    Url::parse(&format!("https://genius.com/{path}")).ok()
}

fn song_url(artist: &str, title: &str) -> Option<Url> {
    let (artist, title) = (slug_words(artist), slug_words(title));
    if artist.is_empty() || title.is_empty() {
        return None;
    }
    page(&format!("{}-{title}-lyrics", capitalized(&artist)))
}

fn album_url(artist: &str, album: &str) -> Option<Url> {
    let (artist, album) = (slug_words(artist), slug_words(album));
    if artist.is_empty() || album.is_empty() {
        return None;
    }
    page(&format!(
        "albums/{}/{}",
        capitalized(&artist),
        capitalized(&album)
    ))
}

fn decode_entities(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        result.push_str(&rest[..at]);
        rest = &rest[at..];
        // Bytes, not text: the next 12 bytes can end inside a character.
        let Some(end) = rest.bytes().take(12).position(|byte| byte == b';') else {
            result.push('&');
            rest = &rest[1..];
            continue;
        };
        let decoded = match &rest[1..end] {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            entity => entity.strip_prefix('#').and_then(|number| {
                match number.strip_prefix(['x', 'X']) {
                    Some(hex) => u32::from_str_radix(hex, 16).ok(),
                    None => number.parse().ok(),
                }
                .and_then(char::from_u32)
            }),
        };
        match decoded {
            Some(c) => {
                result.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                result.push('&');
                rest = &rest[1..];
            }
        }
    }
    result.push_str(rest);
    result
}

/// Name of the tag that starts `tag`: "div class=x" -> "div".
fn tag_name(tag: &str) -> &str {
    tag.split(|c: char| c.is_whitespace() || c == '/')
        .next()
        .unwrap_or("")
}

/// Text of the lyrics containers, without the page's own additions inside them.
pub fn parse_lyrics(html: &str) -> Option<String> {
    const MARKER: &str = "data-lyrics-container=\"true\"";
    let mut parts = Vec::new();
    let mut rest = html;
    while let Some(found) = rest.find(MARKER) {
        rest = &rest[found..];
        let Some(open) = rest.find('>') else { break };
        rest = &rest[open + 1..];
        let mut text = String::new();
        let mut depth = 1usize;
        // Depth of the part to leave out, while inside one.
        let mut excluded: Option<usize> = None;
        while depth > 0 {
            let Some(at) = rest.find('<') else { break };
            if excluded.is_none() {
                text.push_str(&rest[..at]);
            }
            rest = &rest[at + 1..];
            let Some(end) = rest.find('>') else { break };
            let tag = &rest[..end];
            rest = &rest[end + 1..];
            if tag.starts_with('!') {
                continue;
            }
            if let Some(closing) = tag.strip_prefix('/') {
                if tag_name(closing) == "div" {
                    depth -= 1;
                    if excluded == Some(depth) {
                        excluded = None;
                    }
                }
                continue;
            }
            match tag_name(tag) {
                "br" if excluded.is_none() => text.push('\n'),
                "div" if !tag.ends_with('/') => {
                    if excluded.is_none() && tag.contains("data-exclude-from-selection") {
                        excluded = Some(depth);
                    }
                    depth += 1;
                }
                _ => {}
            }
        }
        parts.push(decode_entities(&text).trim().to_owned());
    }
    let joined = parts.join("\n");
    let lines: Vec<&str> = joined.lines().map(str::trim).collect();
    let text = lines.join("\n");
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// Song titles of an album page in the order of the page.
pub fn parse_tracklist(html: &str) -> Vec<String> {
    const MARKER: &str = "class=\"chart_row-content-title\"";
    let mut tracks = Vec::new();
    let mut rest = html;
    while let Some(found) = rest.find(MARKER) {
        rest = &rest[found + MARKER.len()..];
        let Some(open) = rest.find('>') else { break };
        rest = &rest[open + 1..];
        let Some(end) = rest.find('<') else { break };
        let title = decode_entities(&rest[..end]);
        let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
        if !title.is_empty() {
            tracks.push(title);
        }
    }
    tracks
}

/// Comparable form of a title: "Numb (Ft. Jay-Z)" and "NUMB" are the same.
pub fn title_key(title: &str) -> String {
    let lower = title.to_lowercase();
    let mut kept = lower.as_str();
    for marker in [
        "(ft",
        "(feat",
        "[ft",
        "[feat",
        " ft.",
        " feat.",
        " featuring ",
    ] {
        if let Some(at) = kept.find(marker) {
            kept = &kept[..at];
        }
    }
    kept.chars().filter(|c| c.is_alphanumeric()).collect()
}

async fn fetch_page(client: &reqwest::Client, url: Url) -> Result<Option<String>, Unavailable> {
    let mut response = client.get(url).send().await.map_err(|_| Unavailable)?;
    let status = response.status();
    if status.as_u16() == 429 || status.is_server_error() {
        return Err(Unavailable);
    }
    if !status.is_success() || response.url().host_str() != Some("genius.com") {
        return Ok(None);
    }
    let mut data = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| Unavailable)? {
        data.extend_from_slice(&chunk);
        if data.len() > MAX_PAGE_BYTES {
            return Ok(None);
        }
    }
    Ok(Some(String::from_utf8_lossy(&data).into_owned()))
}

fn token() -> Option<String> {
    std::env::var("MINIPLY_GENIUS_TOKEN")
        .ok()
        .map(|t| t.trim().to_owned())
        .filter(|t| !t.is_empty())
}

/// `response` of an API call; None for a refused token or an unknown item.
async fn api(
    client: &reqwest::Client,
    token: &str,
    path: &str,
    params: &[(&str, &str)],
) -> Result<Option<Value>, Unavailable> {
    let url = Url::parse_with_params(&format!("https://api.genius.com/{path}"), params)
        .map_err(|_| Unavailable)?;
    let response = client
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| Unavailable)?;
    let status = response.status();
    if status.as_u16() == 429 || status.is_server_error() {
        return Err(Unavailable);
    }
    if !status.is_success() {
        return Ok(None);
    }
    let data = response.bytes().await.map_err(|_| Unavailable)?;
    let body: Value = serde_json::from_slice(&data).map_err(|_| Unavailable)?;
    Ok(body.get("response").cloned())
}

/// Songs Genius finds for the words, by the given artist only.
async fn search_songs(
    client: &reqwest::Client,
    token: &str,
    words: &str,
    artist: &str,
) -> Result<Vec<Value>, Unavailable> {
    let response = api(client, token, "search", &[("q", words), ("per_page", "10")]).await?;
    let artist = title_key(artist);
    Ok(response
        .as_ref()
        .and_then(|r| r.get("hits"))
        .and_then(Value::as_array)
        .map(|hits| {
            hits.iter()
                .filter_map(|hit| hit.get("result"))
                .filter(|song| {
                    song.pointer("/primary_artist/name")
                        .and_then(Value::as_str)
                        .is_some_and(|name| title_key(name) == artist)
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default())
}

pub async fn lyrics(
    client: &reqwest::Client,
    artist: &str,
    title: &str,
) -> Result<Option<String>, Unavailable> {
    let wanted = title_key(title);
    let mut address = None;
    if let Some(token) = token() {
        address = search_songs(client, &token, &format!("{artist} {title}"), artist)
            .await?
            .iter()
            .find(|song| {
                song.get("title")
                    .and_then(Value::as_str)
                    .is_some_and(|t| title_key(t) == wanted)
            })
            .and_then(|song| song.get("url")?.as_str()?.parse::<Url>().ok())
            .filter(|url| url.scheme() == "https" && url.host_str() == Some("genius.com"));
    }
    let Some(url) = address.or_else(|| song_url(artist, title)) else {
        return Ok(None);
    };
    Ok(fetch_page(client, url)
        .await?
        .and_then(|html| parse_lyrics(&html)))
}

/// Track list through the API: an album is reached through one of its songs.
async fn api_tracklist(
    client: &reqwest::Client,
    token: &str,
    artist: &str,
    album: &str,
) -> Result<Vec<String>, Unavailable> {
    let wanted = title_key(album);
    let songs = search_songs(client, token, &format!("{artist} {album}"), artist).await?;
    let mut album_id = None;
    for song in songs.iter().take(5) {
        let Some(id) = song.get("id").and_then(Value::as_u64) else {
            continue;
        };
        let details = api(client, token, &format!("songs/{id}"), &[]).await?;
        let found = details.as_ref().and_then(|d| d.pointer("/song/album"));
        if let Some(found) = found
            && found
                .get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| title_key(name) == wanted)
        {
            album_id = found.get("id").and_then(Value::as_u64);
            break;
        }
    }
    let Some(album_id) = album_id else {
        return Ok(Vec::new());
    };
    let mut tracks = Vec::new();
    for page in 1..=5 {
        let page = page.to_string();
        let Some(response) = api(
            client,
            token,
            &format!("albums/{album_id}/tracks"),
            &[("per_page", "50"), ("page", &page)],
        )
        .await?
        else {
            break;
        };
        tracks.extend(
            response
                .get("tracks")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|t| t.pointer("/song/title")?.as_str().map(str::to_owned)),
        );
        if response.get("next_page").is_none_or(Value::is_null) {
            break;
        }
    }
    Ok(tracks)
}

/// `{"tracks": [...]}` for the metadata cache.
pub async fn tracklist(
    client: &reqwest::Client,
    artist: &str,
    album: &str,
) -> Result<Option<Value>, Unavailable> {
    let mut tracks = Vec::new();
    if let Some(token) = token() {
        tracks = api_tracklist(client, &token, artist, album).await?;
    }
    if tracks.is_empty()
        && let Some(url) = album_url(artist, album)
    {
        tracks = fetch_page(client, url)
            .await?
            .map(|html| parse_tracklist(&html))
            .unwrap_or_default();
    }
    Ok((!tracks.is_empty()).then(|| json!({ "tracks": tracks })))
}

/// Number songs 1, 2, 3 … by the Genius list of their album, songs not on the
/// list behind those that are. A list is used only if it names at least half of
/// the album's songs: otherwise it is probably a different release with the
/// same name.
pub fn apply_tracklists<'a>(
    library: impl Iterator<Item = &'a crate::catalog::Media>,
    known: &HashMap<String, Entry>,
    items: &mut [crate::catalog::Media],
) {
    let mut albums: HashMap<&str, Vec<&crate::catalog::Media>> = HashMap::new();
    for media in library {
        if let Some(key) = media.album_key.as_deref() {
            albums.entry(key).or_default().push(media);
        }
    }
    let mut numbers: HashMap<&str, u32> = HashMap::new();
    for (key, mut songs) in albums {
        let Some(tracks) = known
            .get(&format!("genius-album:{key}"))
            .and_then(|entry| entry.value.get("tracks"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        let mut positions = HashMap::new();
        for (index, track) in tracks.iter().enumerate() {
            if let Some(title) = track.as_str() {
                positions
                    .entry(title_key(title))
                    .or_insert(index as u32 + 1);
            }
        }
        let matched = songs
            .iter()
            .filter(|song| positions.contains_key(&title_key(&song.title)))
            .count();
        if matched == 0 || matched * 2 < songs.len() {
            continue;
        }
        songs.sort_by_cached_key(|song| {
            let position = positions
                .get(&title_key(&song.title))
                .copied()
                .unwrap_or_else(|| UNLISTED_TRACK + song.track_number.unwrap_or(0));
            (position, song.title.clone())
        });
        for (index, song) in songs.into_iter().enumerate() {
            numbers.insert(song.id.as_str(), index as u32 + 1);
        }
    }
    for media in items {
        if let Some(number) = numbers.get(media.id.as_str()) {
            media.track_number = Some(*number);
            media.disc_number = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ampersand_before_a_long_character_does_not_crash() {
        // The first 12 bytes end inside the three-byte space.
        let text = "&#x27;a b\u{2005}c";
        assert_eq!(decode_entities(text), "'a b\u{2005}c");
        assert_eq!(
            decode_entities("a &bcdefgh\u{2005}i; j"),
            "a &bcdefgh\u{2005}i; j"
        );
    }

    #[test]
    fn page_addresses() {
        assert_eq!(
            song_url("Linkin Park", "Don't Stay").unwrap().as_str(),
            "https://genius.com/Linkin-park-dont-stay-lyrics"
        );
        assert_eq!(
            song_url("YEAT", "U could").unwrap().as_str(),
            "https://genius.com/Yeat-u-could-lyrics"
        );
        assert_eq!(
            song_url("Simon & Garfunkel", "Mrs. Robinson")
                .unwrap()
                .as_str(),
            "https://genius.com/Simon-and-garfunkel-mrs-robinson-lyrics"
        );
        assert_eq!(
            album_url("YEAT", "Luh Leakyz Vol. 1").unwrap().as_str(),
            "https://genius.com/albums/Yeat/Luh-leakyz-vol-1"
        );
        assert!(song_url("", "Titel").is_none());
    }

    #[test]
    fn lyrics_without_page_additions() {
        let html = r#"<div id="x"><div data-lyrics-container="true" class="a">
            <div data-exclude-from-selection="true"><div><span>12 Contributors</span></div></div>
            [Part 1]<br/>First <a href="/x"><span>line &amp; more</span></a><br>it&#x27;s second
            </div><div>not this</div>
            <div data-lyrics-container="true" class="a">Third<br/></div></div>"#;
        assert_eq!(
            parse_lyrics(html).unwrap(),
            "[Part 1]\nFirst line & more\nit's second\nThird"
        );
        assert!(parse_lyrics("<div>nothing</div>").is_none());
    }

    #[test]
    fn tracks_in_page_order() {
        let html = r#"<h3 class="chart_row-content-title">
              One &amp; Two (Ft.&nbsp;Guest)
              <span class="chart_row-content-title-subtitle">Lyrics</span></h3>
            <h3 class="chart_row-content-title"> Three <span>Lyrics</span></h3>"#;
        assert_eq!(parse_tracklist(html), ["One & Two (Ft. Guest)", "Three"]);
    }

    #[test]
    fn comparable_titles() {
        assert_eq!(title_key("Numb (Ft. Jay-Z)"), title_key("NUMB"));
        assert_eq!(title_key("I'M SPENT"), title_key("I’m Spent"));
        assert_ne!(title_key("Numb"), title_key("Numb Encore"));
    }

    fn song(title: &str, number: Option<u32>) -> crate::catalog::Media {
        crate::catalog::Media {
            id: title.into(),
            path: format!("Musik/A/{title}.mp3"),
            name: format!("{title}.mp3"),
            kind: "audio".into(),
            title: title.into(),
            artist: None,
            album: None,
            duration: None,
            bytes: 1,
            modified: 0,
            modified_nanos: 0,
            playback: None,
            album_key: Some("Musik/A".into()),
            album_artist: None,
            track_number: number,
            disc_number: Some(2),
            cover_id: None,
            series_key: None,
            season_folder: None,
            season: None,
            episode: None,
            playback_path: None,
            hls: false,
            tag_artist: None,
            tag_album: None,
            embedded_art: false,
            subtitles: Vec::new(),
            has_lyrics: false,
            embedded_lyrics: false,
            gain_db: None,
            intro: None,
            added: None,
            censored: false,
            featured: Vec::new(),
            artist_credit: None,
            tag_title: None,
            file_title: String::new(),
        }
    }

    fn known(tracks: &[&str]) -> HashMap<String, Entry> {
        HashMap::from([(
            "genius-album:Musik/A".to_owned(),
            Entry {
                query: String::new(),
                found: true,
                fetched_at: 0,
                value: json!({ "tracks": tracks }),
            },
        )])
    }

    #[test]
    fn sorting_by_the_list() {
        let library = [song("B", Some(1)), song("A", Some(2)), song("X", Some(3))];
        let mut items = library.to_vec();
        apply_tracklists(library.iter(), &known(&["A", "B (Ft. C)"]), &mut items);
        let numbers: Vec<_> = items.iter().map(|m| m.track_number).collect();
        assert_eq!(numbers, [Some(2), Some(1), Some(3)]);
        assert_eq!(items[0].disc_number, None);
    }

    #[test]
    fn unlisted_songs_continue_the_numbering() {
        let library = [
            song("Z", None),
            song("Y", None),
            song("C", Some(9)),
            song("A", Some(7)),
        ];
        let mut items = library.to_vec();
        let list = ["A", "Other", "Another", "C"];
        apply_tracklists(library.iter(), &known(&list), &mut items);
        let numbers: Vec<_> = items.iter().map(|m| m.track_number).collect();
        assert_eq!(numbers, [Some(4), Some(3), Some(2), Some(1)]);
    }

    #[test]
    fn foreign_list_is_ignored() {
        let library = [song("B", Some(1)), song("A", Some(2)), song("X", Some(3))];
        let mut items = library.to_vec();
        apply_tracklists(library.iter(), &known(&["A", "Other"]), &mut items);
        assert_eq!(items[0].track_number, Some(1));
        assert_eq!(items[0].disc_number, Some(2));
    }
}
