//! Lyrics, subtitles and uploads from the app.

use crate::{ApiError, AppState, catalog::Media, file_access, metadata};
use axum::{
    Json,
    body::Body,
    extract::{Path, Query, State},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{io::Read, time::Duration};
use tokio::io::AsyncWriteExt;

const MAX_TEXT_BYTES: u64 = 5 * 1024 * 1024;

/// Text files come in many encodings: UTF-8 (with or without BOM), UTF-16
/// with BOM, or Windows-1252/Latin-1 from older tools.
pub fn decode_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    let utf16 = |data: &[u8], little: bool| {
        let units: Vec<u16> = data
            .chunks_exact(2)
            .map(|c| {
                if little {
                    u16::from_le_bytes([c[0], c[1]])
                } else {
                    u16::from_be_bytes([c[0], c[1]])
                }
            })
            .collect();
        String::from_utf16_lossy(&units)
    };
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return utf16(rest, true);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return utf16(rest, false);
    }
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_owned(),
        // Latin-1 maps every byte; good enough for German subtitles.
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

fn read_text(state: &AppState, media: &Media) -> Option<String> {
    let file = file_access::open_regular(&state.root, &media.path).ok()?;
    let mut data = Vec::new();
    file.take(MAX_TEXT_BYTES + 1).read_to_end(&mut data).ok()?;
    if data.len() as u64 > MAX_TEXT_BYTES {
        return None;
    }
    Some(decode_text(&data).replace("\r\n", "\n").replace('\r', "\n"))
}

/// `[01:23.45]` style time stamps make lyrics synchronised.
pub fn is_synced(text: &str) -> bool {
    text.lines()
        .filter(|l| {
            // Bytes: a line may start with any characters, like "[日本語]".
            let l = l.trim_start().as_bytes();
            l.len() > 7
                && l[0] == b'['
                && l[1].is_ascii_digit()
                && l[2].is_ascii_digit()
                && l[3] == b':'
        })
        .count()
        >= 3
}

const LYRICS_START: Duration = Duration::from_secs(30);
const LYRICS_PAUSE: Duration = Duration::from_secs(3);
/// New songs are picked up this soon after a scan.
const LYRICS_IDLE: Duration = Duration::from_secs(60);
const LYRICS_RETRY: Duration = Duration::from_secs(15 * 60);

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Lyrics {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub synced: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plain: Option<String>,
    #[serde(default)]
    pub instrumental: bool,
    pub source: String,
}

fn lyrics_from_text(text: String, source: &str) -> Option<Lyrics> {
    let text = text.trim().to_owned();
    if text.is_empty() {
        return None;
    }
    Some(if is_synced(&text) {
        Lyrics {
            synced: Some(text),
            source: source.into(),
            ..Lyrics::default()
        }
    } else {
        Lyrics {
            plain: Some(text),
            source: source.into(),
            ..Lyrics::default()
        }
    })
}

fn stem(name: &str) -> &str {
    name.rsplit_once('.').map_or(name, |(stem, _)| stem)
}

fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(dir, _)| dir)
}

/// `Err` when the service is out of order, unlike "no text known".
async fn lrclib_lyrics(
    state: &AppState,
    media: &Media,
    artist: &str,
) -> Result<Option<Lyrics>, ()> {
    let duration = media
        .duration
        .map(|d| format!("{}", d.round() as u64))
        .unwrap_or_default();
    let mut params = vec![
        ("track_name", media.title.as_str()),
        ("artist_name", artist),
    ];
    if let Some(album) = media.album.as_deref() {
        params.push(("album_name", album));
    }
    if !duration.is_empty() {
        params.push(("duration", duration.as_str()));
    }
    let url =
        reqwest::Url::parse_with_params("https://lrclib.net/api/get", &params).map_err(|_| ())?;
    let response = state.http.get(url).send().await.map_err(|_| ())?;
    let status = response.status();
    if status.is_server_error() || status.as_u16() == 429 {
        return Err(());
    }
    if !status.is_success() {
        return Ok(None);
    }
    let bytes = response.bytes().await.map_err(|_| ())?;
    let body: Value = serde_json::from_slice(&bytes).map_err(|_| ())?;
    let text = |k: &str| {
        body.get(k)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let instrumental = body
        .get("instrumental")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let lyrics = Lyrics {
        synced: text("syncedLyrics"),
        plain: text("plainLyrics"),
        instrumental,
        source: "lrclib".into(),
    };
    Ok((lyrics.synced.is_some() || lyrics.plain.is_some() || instrumental).then_some(lyrics))
}

/// Letters and digits only, lower case: "God’s Plan" and "Gods Plan" match.
fn lyrics_key(value: &str) -> String {
    value
        .to_lowercase()
        .split(['(', '['])
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// The same song: the title matches, the artist is one of the credits and the
/// length (when both know it) differs by at most a few seconds.
fn same_song(
    title: &str,
    artists: &str,
    seconds: Option<f64>,
    media: &Media,
    artist: &str,
) -> bool {
    let wanted = lyrics_key(&media.title);
    let artist = lyrics_key(artist);
    let credits = lyrics_key(artists);
    !wanted.is_empty()
        && lyrics_key(title) == wanted
        && !artist.is_empty()
        && (credits.contains(&artist) || artist.contains(&credits) && !credits.is_empty())
        && match (seconds, media.duration) {
            (Some(found), Some(own)) if found > 0.0 => (found - own).abs() <= 8.0,
            _ => true,
        }
}

/// LRCLIB's search, when the exact lookup misses (other album name or a
/// slightly different length). Prefers entries with time stamps.
async fn lrclib_search(
    state: &AppState,
    media: &Media,
    artist: &str,
) -> Result<Option<Lyrics>, ()> {
    let url = reqwest::Url::parse_with_params(
        "https://lrclib.net/api/search",
        &[
            ("track_name", media.title.as_str()),
            ("artist_name", artist),
        ],
    )
    .map_err(|_| ())?;
    let response = state.http.get(url).send().await.map_err(|_| ())?;
    if response.status().is_server_error() || response.status().as_u16() == 429 {
        return Err(());
    }
    let body: Value =
        serde_json::from_slice(&response.bytes().await.map_err(|_| ())?).map_err(|_| ())?;
    let text = |item: &Value, key: &str| {
        item.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let mut matches: Vec<&Value> = body
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter(|item| {
                    same_song(
                        item.get("trackName").and_then(Value::as_str).unwrap_or(""),
                        item.get("artistName").and_then(Value::as_str).unwrap_or(""),
                        item.get("duration").and_then(Value::as_f64),
                        media,
                        artist,
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    matches.sort_by_key(|item| text(item, "syncedLyrics").is_none());
    Ok(matches.first().and_then(|item| {
        let lyrics = Lyrics {
            synced: text(item, "syncedLyrics"),
            plain: text(item, "plainLyrics"),
            instrumental: item
                .get("instrumental")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            source: "lrclib".into(),
        };
        (lyrics.synced.is_some() || lyrics.plain.is_some() || lyrics.instrumental).then_some(lyrics)
    }))
}

/// lyrics.ovh: plain text by artist and title, a wide collection.
async fn lyrics_ovh(state: &AppState, media: &Media, artist: &str) -> Option<String> {
    let mut url = reqwest::Url::parse("https://api.lyrics.ovh/v1/").ok()?;
    url.path_segments_mut()
        .ok()?
        .extend([artist, media.title.as_str()]);
    let response = state.http.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: Value = serde_json::from_slice(&response.bytes().await.ok()?).ok()?;
    let text = body.get("lyrics")?.as_str()?.trim();
    // Some answers start with a "Paroles de la chanson …" line from the source site.
    let text = match text.split_once('\n') {
        Some((first, rest)) if first.starts_with("Paroles de la chanson") => rest.trim(),
        _ => text,
    };
    (text.len() > 20).then(|| text.replace("\r\n", "\n"))
}

/// NetEase Cloud Music: time-stamped lyrics, also for songs nobody added to LRCLIB.
async fn netease_lyrics(state: &AppState, media: &Media, artist: &str) -> Option<String> {
    let query = format!("{artist} {}", media.title);
    let url = reqwest::Url::parse_with_params(
        "https://music.163.com/api/search/get",
        &[("s", query.as_str()), ("type", "1"), ("limit", "10")],
    )
    .ok()?;
    let body: Value =
        serde_json::from_slice(&state.http.get(url).send().await.ok()?.bytes().await.ok()?).ok()?;
    let song = body
        .pointer("/result/songs")?
        .as_array()?
        .iter()
        .find(|song| {
            let artists: Vec<&str> = song
                .get("artists")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(|a| a.get("name").and_then(Value::as_str))
                        .collect()
                })
                .unwrap_or_default();
            same_song(
                song.get("name").and_then(Value::as_str).unwrap_or(""),
                &artists.join(" "),
                song.get("duration")
                    .and_then(Value::as_f64)
                    .map(|ms| ms / 1000.0),
                media,
                artist,
            )
        })?;
    let id = song.get("id")?.as_u64()?.to_string();
    let url = reqwest::Url::parse_with_params(
        "https://music.163.com/api/song/lyric",
        &[("id", id.as_str()), ("lv", "1"), ("kv", "1"), ("tv", "-1")],
    )
    .ok()?;
    let body: Value =
        serde_json::from_slice(&state.http.get(url).send().await.ok()?.bytes().await.ok()?).ok()?;
    let lyric = body.pointer("/lrc/lyric")?.as_str()?.trim();
    // Only real time stamps count; "纯音乐" marks a piece without words.
    let lines = lyric
        .lines()
        .filter(|line| {
            line.starts_with('[') && line.chars().nth(1).is_some_and(|c| c.is_ascii_digit())
        })
        .count();
    (lines >= 5 && !lyric.contains("纯音乐")).then(|| lyric.to_owned())
}

/// GET /v1/lyrics/{id}: `.lrc`/`.txt` next to the file, embedded lyrics,
/// then (if online metadata is enabled) the text from Genius and time stamps
/// from LRCLIB, cached in SQLite.
pub async fn lyrics(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Lyrics>, ApiError> {
    let media = state.media(&id).await?;
    if media.kind != "audio" {
        return Err(ApiError::not_found());
    }
    let siblings: Vec<Media> = {
        let catalog = state.catalog.read().await;
        let dir = parent(&media.path);
        let track = stem(&media.name).to_lowercase();
        let mut list: Vec<Media> = catalog
            .files
            .values()
            .filter(|m| {
                parent(&m.path) == dir && stem(&m.name).to_lowercase() == track && m.id != media.id
            })
            .filter(|m| crate::organize::is_lyrics(&m.path))
            .cloned()
            .collect();
        // .lrc before .txt
        list.sort_by_key(|m| !m.name.to_lowercase().ends_with(".lrc"));
        list
    };
    let local = {
        let state = state.clone();
        let media = media.clone();
        tokio::task::spawn_blocking(move || {
            for file in &siblings {
                if let Some(found) =
                    read_text(&state, file).and_then(|t| lyrics_from_text(t, "file"))
                {
                    return Some(found);
                }
            }
            if !media.embedded_lyrics {
                return None;
            }
            use lofty::prelude::*;
            let file = file_access::open_regular(&state.root, &media.path).ok()?;
            let tagged = lofty::probe::Probe::new(file)
                .guess_file_type()
                .ok()?
                .read()
                .ok()?;
            let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;
            let text = tag
                .get_string(lofty::tag::ItemKey::Lyrics)
                .or_else(|| tag.get_string(lofty::tag::ItemKey::UnsyncLyrics))?;
            lyrics_from_text(text.to_owned(), "tag")
        })
        .await
        .map_err(|_| ApiError::internal())?
    };
    if let Some(found) = local {
        return Ok(Json(found));
    }
    let Some(artist) = media.artist.clone() else {
        return Err(ApiError::not_found());
    };
    if !metadata::enabled() {
        return Err(ApiError::not_found());
    }
    let looked = online_lyrics(&state, &media, &artist)
        .await
        .map_err(|_| ApiError(StatusCode::BAD_GATEWAY, "lyrics service unavailable"))?;
    looked.found.map(Json).ok_or_else(ApiError::not_found)
}

fn lyrics_query(media: &Media, artist: &str) -> String {
    format!("genius-v2\u{1f}{}\u{1f}{artist}", media.title)
}

fn lyrics_fresh(entry: &metadata::Entry, query: &str, current: u64) -> bool {
    let max_age = if entry.found { 365 } else { 14 } * 86_400;
    // Lyrics found before more sources were added stay; what was not found
    // then is looked up again with them.
    let earlier = entry.found && entry.query == query.replacen("genius-v2", "genius-v1", 1);
    (entry.query == query || earlier) && current.saturating_sub(entry.fetched_at) < max_age
}

/// A song without its own lyrics that has not been looked up lately.
fn needs_lyrics(media: &Media, entry: Option<&metadata::Entry>, current: u64) -> bool {
    media.kind == "audio"
        && !media.has_lyrics
        && media.artist.as_deref().is_some_and(|artist| {
            !entry.is_some_and(|e| lyrics_fresh(e, &lyrics_query(media, artist), current))
        })
}

struct LookedUp {
    found: Option<Lyrics>,
    /// Both services answered, so the result is final and was stored.
    complete: bool,
}

async fn online_lyrics(state: &AppState, media: &Media, artist: &str) -> Result<LookedUp, ()> {
    let key = format!("lyrics:{}", media.id);
    let query = lyrics_query(media, artist);
    if let Some(entry) = state
        .metadata
        .read()
        .await
        .get(&key)
        .filter(|e| lyrics_fresh(e, &query, crate::catalog::now()))
    {
        let found = serde_json::from_value::<Lyrics>(entry.value.clone())
            .ok()
            .filter(|_| entry.found);
        return Ok(LookedUp {
            found,
            complete: true,
        });
    }
    let (genius, lrclib) = tokio::join!(
        crate::genius::lyrics(&state.http, artist, &media.title),
        lrclib_lyrics(state, media, artist)
    );
    let complete = genius.is_ok() && lrclib.is_ok();
    if genius.is_err() && lrclib.is_err() {
        return Err(());
    }
    let text = genius.ok().flatten();
    let mut lyrics = lrclib.ok().flatten();
    // Not found exactly: LRCLIB's search, then NetEase for time stamps and
    // lyrics.ovh for the text, so that fewer songs stay without lyrics.
    if lyrics
        .as_ref()
        .is_none_or(|l| l.synced.is_none() && !l.instrumental)
        && let Ok(Some(searched)) = lrclib_search(state, media, artist).await
    {
        lyrics = Some(searched);
    }
    if lyrics
        .as_ref()
        .is_none_or(|l| l.synced.is_none() && !l.instrumental)
        && let Some(synced) = netease_lyrics(state, media, artist).await
    {
        let mut found = lyrics.unwrap_or_default();
        found.synced = Some(synced);
        found.source = "netease".into();
        lyrics = Some(found);
    }
    // Plain text: Genius, else lyrics.ovh when nothing else has words.
    let mut plain_source = text.as_ref().map(|_| "genius");
    let mut plain = text;
    if plain.is_none()
        && lyrics
            .as_ref()
            .is_none_or(|l| l.plain.is_none() && l.synced.is_none() && !l.instrumental)
        && let Some(found) = lyrics_ovh(state, media, artist).await
    {
        plain = Some(found);
        plain_source = Some("lyrics.ovh");
    }
    // Genius has no time stamps: the synced lines stay, so the text can run along.
    // The source named is the one of the time stamps, else the one of the text.
    let found = match (lyrics, plain) {
        (None, None) => None,
        (lyrics, plain) => {
            let mut lyrics = lyrics.unwrap_or_default();
            if lyrics.synced.is_none()
                && let Some(source) = plain_source
            {
                lyrics.source = source.into();
            }
            if lyrics.source.is_empty() {
                lyrics.source = "lrclib".into();
            }
            lyrics.plain = plain.or(lyrics.plain);
            Some(lyrics)
        }
    };
    if complete {
        let entry = metadata::Entry {
            query,
            found: found.is_some(),
            fetched_at: crate::catalog::now(),
            value: found
                .as_ref()
                .map(|l| serde_json::to_value(l).unwrap_or(Value::Null))
                .unwrap_or(Value::Null),
        };
        let _ = state.store.save_metadata(key.clone(), entry.clone()).await;
        state.metadata.write().await.insert(key, entry);
    }
    Ok(LookedUp { found, complete })
}

/// Fetches the lyrics of every song ahead of time, so that they are there at
/// once when a song plays. One at a time, to go easy on both services.
pub fn spawn_lyrics(state: AppState) {
    if !metadata::enabled() {
        return;
    }
    tokio::spawn(async move {
        tokio::time::sleep(LYRICS_START).await;
        loop {
            let current = crate::catalog::now();
            let next = {
                let catalog = state.catalog.read().await;
                let known = state.metadata.read().await;
                catalog
                    .files
                    .values()
                    .find(|m| needs_lyrics(m, known.get(&format!("lyrics:{}", m.id)), current))
                    .cloned()
            };
            let wait = match next {
                None => LYRICS_IDLE,
                Some(media) => {
                    let artist = media.artist.clone().unwrap_or_default();
                    match online_lyrics(&state, &media, &artist).await {
                        Ok(looked) if looked.complete => LYRICS_PAUSE,
                        _ => {
                            tracing::warn!("lyrics: services unreachable, retrying later");
                            LYRICS_RETRY
                        }
                    }
                }
            };
            tokio::time::sleep(wait).await;
        }
    });
}

/// SRT -> WebVTT: header plus `.` instead of `,` in cue timings.
pub fn to_webvtt(text: &str) -> String {
    let text = text.trim_start_matches('\u{feff}');
    if text.trim_start().starts_with("WEBVTT") {
        return text.to_owned();
    }
    let mut out = String::from("WEBVTT\n\n");
    for line in text.lines() {
        if line.contains("-->") {
            out.push_str(&line.replace(',', "."));
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    out
}

/// GET /v1/subtitles/{id}: a `.srt` or `.vtt` file as UTF-8 WebVTT.
pub async fn subtitles(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let media = state.media(&id).await?;
    if media.kind != "file" || !crate::organize::is_subtitle(&media.path) {
        return Err(ApiError::not_found());
    }
    let text = tokio::task::spawn_blocking(move || read_text(&state, &media))
        .await
        .map_err(|_| ApiError::internal())?
        .ok_or_else(ApiError::not_found)?;
    Ok((
        [(header::CONTENT_TYPE, "text/vtt; charset=utf-8")],
        to_webvtt(&text),
    )
        .into_response())
}

pub fn uploads_enabled() -> bool {
    matches!(
        std::env::var("MINIPLY_UPLOADS")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "1" | "true" | "on" | "yes"
    )
}

/// One visible path component: no hidden names, separators or controls.
fn valid_component(part: &str) -> bool {
    !part.is_empty()
        && part.len() <= 255
        && part != "."
        && part != ".."
        && !part.starts_with('.')
        && !part
            .chars()
            .any(|c| c == '/' || c == '\\' || c.is_control())
        && part.trim() == part
}

/// Validated relative directory ("" = media root) and file name.
pub fn upload_target(directory: &str, name: &str) -> Option<(Vec<String>, String)> {
    let parts: Vec<String> = directory
        .split('/')
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect();
    if parts.len() > 16 || !parts.iter().all(|p| valid_component(p)) || !valid_component(name) {
        return None;
    }
    if !name.contains('.') {
        return None;
    }
    Some((parts, name.to_owned()))
}

#[derive(Deserialize)]
pub struct UploadQuery {
    #[serde(default)]
    path: String,
    name: String,
}

/// POST /v1/upload?path=Musik/Album&name=01 Titel.mp3 with the file as body.
/// Written to a hidden temporary file, then linked into place without ever
/// replacing an existing file. Requires `MINIPLY_UPLOADS=1` and write access.
pub async fn upload(
    State(state): State<AppState>,
    Query(query): Query<UploadQuery>,
    body: Body,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    if !uploads_enabled() {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "uploads are disabled on this server (MINIPLY_UPLOADS)",
        ));
    }
    let (parts, name) = upload_target(&query.path, &query.name).ok_or(ApiError(
        StatusCode::BAD_REQUEST,
        "invalid target folder or file name",
    ))?;
    let directory = parts.join("/");
    let target = if directory.is_empty() {
        name.clone()
    } else {
        format!("{directory}/{name}")
    };
    let temp = format!(".miniply-upload/{}.part", uuid::Uuid::new_v4());
    let root = state.root.clone();
    let (file, exists) = {
        let root = root.clone();
        let directory = directory.clone();
        let target = target.clone();
        let temp = temp.clone();
        tokio::task::spawn_blocking(move || -> std::io::Result<(std::fs::File, bool)> {
            if root.symlink_metadata(&target).is_ok() {
                return Ok((tempfile_placeholder()?, true));
            }
            root.create_dir_all(".miniply-upload")?;
            if !directory.is_empty() {
                root.create_dir_all(&directory)?;
            }
            let mut options = cap_std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            Ok((root.open_with(&temp, &options)?.into_std(), false))
        })
        .await
        .map_err(|_| ApiError::internal())?
        .map_err(|error| {
            tracing::warn!("upload: cannot create target: {error}");
            ApiError(
                StatusCode::INSUFFICIENT_STORAGE,
                "server cannot write to the media folder",
            )
        })?
    };
    if exists {
        return Err(ApiError(
            StatusCode::CONFLICT,
            "a file with this name already exists",
        ));
    }
    let mut output = tokio::fs::File::from_std(file);
    let mut stream = body.into_data_stream();
    let mut written: u64 = 0;
    let mut failure: Option<ApiError> = None;
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(data) => {
                written += data.len() as u64;
                if output.write_all(&data).await.is_err() {
                    failure = Some(ApiError(
                        StatusCode::INSUFFICIENT_STORAGE,
                        "writing failed (disk full?)",
                    ));
                    break;
                }
            }
            Err(_) => {
                failure = Some(ApiError(StatusCode::BAD_REQUEST, "upload interrupted"));
                break;
            }
        }
    }
    if failure.is_none() && output.sync_all().await.is_err() {
        failure = Some(ApiError(
            StatusCode::INSUFFICIENT_STORAGE,
            "writing failed (disk full?)",
        ));
    }
    drop(output);
    let finish = {
        let root = root.clone();
        let temp = temp.clone();
        let target = target.clone();
        let failed = failure.is_some() || written == 0;
        tokio::task::spawn_blocking(move || -> std::io::Result<bool> {
            if failed {
                let _ = root.remove_file(&temp);
                return Ok(false);
            }
            // hard_link never replaces an existing file.
            let linked = root.hard_link(&temp, &root, &target);
            let _ = root.remove_file(&temp);
            match linked {
                Ok(()) => Ok(true),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
                Err(error) => Err(error),
            }
        })
        .await
        .map_err(|_| ApiError::internal())?
    };
    if let Some(error) = failure {
        return Err(error);
    }
    if written == 0 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "empty upload"));
    }
    match finish {
        Ok(true) => {}
        Ok(false) => {
            return Err(ApiError(
                StatusCode::CONFLICT,
                "a file with this name already exists",
            ));
        }
        Err(error) => {
            tracing::warn!("upload: cannot move file into place: {error}");
            return Err(ApiError(
                StatusCode::INSUFFICIENT_STORAGE,
                "server cannot write to the media folder",
            ));
        }
    }
    let scanner = state.clone();
    tokio::spawn(async move {
        let _ = scanner.rescan().await;
    });
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({"path": target, "bytes": written})),
    ))
}

/// Parts are small. Reading a refused one to its end lets the client see the
/// answer instead of a connection that stops accepting data.
const MAX_REFUSED_BYTES: u64 = 64 * 1024 * 1024;

async fn drain(stream: &mut axum::body::BodyDataStream) {
    let mut seen = 0;
    while seen < MAX_REFUSED_BYTES {
        match stream.next().await {
            Some(Ok(data)) => seen += data.len() as u64,
            _ => break,
        }
    }
}

const RESUMABLE_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(14 * 86_400);

fn resumable_part(id: &str) -> Option<String> {
    let valid = id.len() == 36 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-');
    valid.then(|| format!(".miniply-upload/{}.resume", id.to_ascii_lowercase()))
}

/// Remembers a finished upload. If its answer got lost on the way, the app
/// asks again and must hear "done", not "this file already exists".
fn resumable_marker(part: &str) -> String {
    format!("{}.done", part.trim_end_matches(".resume"))
}

fn require_uploads() -> Result<(), ApiError> {
    if uploads_enabled() {
        Ok(())
    } else {
        Err(ApiError(
            StatusCode::FORBIDDEN,
            "uploads are disabled on this server (MINIPLY_UPLOADS)",
        ))
    }
}

/// Abandoned uploads must not fill the SSD.
fn remove_stale_parts(root: &cap_std::fs::Dir) {
    let Ok(entries) = root.read_dir(".miniply-upload") else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let stale = entry
            .metadata()
            .ok()
            .and_then(|meta| meta.modified().ok())
            .map(|time| time.into_std())
            .and_then(|time| time.elapsed().ok())
            .is_some_and(|age| age > RESUMABLE_MAX_AGE);
        let name = name.to_string_lossy();
        if stale && (name.ends_with(".resume") || name.ends_with(".done")) {
            let _ = entry.remove_file();
        }
    }
}

/// GET /v1/uploads/{id}: how many bytes arrived. Unknown IDs have zero, so a
/// 404 always means an older server without resumable uploads.
pub async fn upload_status(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_uploads()?;
    let part = resumable_part(&id).ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid upload ID"))?;
    let root = state.root.clone();
    let received = tokio::task::spawn_blocking(move || root.metadata(&part).map_or(0, |m| m.len()))
        .await
        .map_err(|_| ApiError::internal())?;
    Ok(Json(serde_json::json!({"received": received})))
}

/// DELETE /v1/uploads/{id}: forget what arrived.
pub async fn upload_cancel(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    require_uploads()?;
    let part = resumable_part(&id).ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid upload ID"))?;
    let root = state.root.clone();
    tokio::task::spawn_blocking(move || {
        let _ = root.remove_file(resumable_marker(&part));
        let _ = root.remove_file(&part);
    })
    .await
    .map_err(|_| ApiError::internal())?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct ChunkQuery {
    offset: u64,
    bytes: u64,
    #[serde(default)]
    path: String,
    name: String,
}

/// PUT /v1/uploads/{id}?offset=N&bytes=TOTAL&path=Musik/Album&name=01.mp3 with
/// the next part as body. Whatever arrives stays, also when the connection
/// drops. The part that completes `bytes` links the file into place (201),
/// never replacing an existing one. Another offset than the stored size is
/// answered with 412, and the client asks for the status again.
pub async fn upload_chunk(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ChunkQuery>,
    body: Body,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    use fs2::FileExt;
    use std::io::{Seek, SeekFrom};
    require_uploads()?;
    let part = resumable_part(&id).ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid upload ID"))?;
    let (parts, name) = upload_target(&query.path, &query.name).ok_or(ApiError(
        StatusCode::BAD_REQUEST,
        "invalid target folder or file name",
    ))?;
    if query.bytes == 0 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "empty upload"));
    }
    let directory = parts.join("/");
    let target = if directory.is_empty() {
        name
    } else {
        format!("{directory}/{name}")
    };
    let finished_as = format!("{target}\n{}", query.bytes);
    enum Opened {
        Finished,
        Exists,
        Busy,
        Ready(std::fs::File, u64),
    }
    let opened = {
        let root = state.root.clone();
        let part = part.clone();
        let target = target.clone();
        let finished_as = finished_as.clone();
        tokio::task::spawn_blocking(move || -> std::io::Result<Opened> {
            if root
                .read_to_string(resumable_marker(&part))
                .is_ok_and(|marker| marker == finished_as)
            {
                return Ok(Opened::Finished);
            }
            if root.symlink_metadata(&target).is_ok() {
                let _ = root.remove_file(&part);
                return Ok(Opened::Exists);
            }
            root.create_dir_all(".miniply-upload")?;
            remove_stale_parts(&root);
            let mut options = cap_std::fs::OpenOptions::new();
            options.write(true).create(true).truncate(false);
            let mut file = root.open_with(&part, &options)?.into_std();
            // A previous request of a dropped connection may still be writing.
            if file.try_lock_exclusive().is_err() {
                return Ok(Opened::Busy);
            }
            let size = file.seek(SeekFrom::End(0))?;
            Ok(Opened::Ready(file, size))
        })
        .await
        .map_err(|_| ApiError::internal())?
        .map_err(|error| {
            tracing::warn!("upload: cannot open part: {error}");
            ApiError(
                StatusCode::INSUFFICIENT_STORAGE,
                "server cannot write to the media folder",
            )
        })?
    };
    let mut stream = body.into_data_stream();
    let (file, mut received) = match opened {
        Opened::Finished => {
            drain(&mut stream).await;
            return Ok((
                StatusCode::CREATED,
                Json(serde_json::json!({"path": target, "bytes": query.bytes})),
            ));
        }
        Opened::Exists => {
            drain(&mut stream).await;
            return Err(ApiError(
                StatusCode::CONFLICT,
                "a file with this name already exists",
            ));
        }
        Opened::Busy => {
            drain(&mut stream).await;
            return Err(ApiError(
                StatusCode::PRECONDITION_FAILED,
                "another request is writing this upload",
            ));
        }
        Opened::Ready(file, size) => (file, size),
    };
    if query.offset != received {
        drain(&mut stream).await;
        return Err(ApiError(
            StatusCode::PRECONDITION_FAILED,
            "offset does not match the received bytes",
        ));
    }
    let mut output = tokio::fs::File::from_std(file);
    while let Some(chunk) = stream.next().await {
        let Ok(data) = chunk else {
            let _ = output.flush().await;
            return Err(ApiError(StatusCode::BAD_REQUEST, "upload interrupted"));
        };
        received += data.len() as u64;
        if received > query.bytes {
            return Err(ApiError(
                StatusCode::BAD_REQUEST,
                "more data than announced",
            ));
        }
        if output.write_all(&data).await.is_err() {
            return Err(ApiError(
                StatusCode::INSUFFICIENT_STORAGE,
                "writing failed (disk full?)",
            ));
        }
    }
    if output.sync_all().await.is_err() {
        return Err(ApiError(
            StatusCode::INSUFFICIENT_STORAGE,
            "writing failed (disk full?)",
        ));
    }
    drop(output);
    if received < query.bytes {
        return Ok((
            StatusCode::OK,
            Json(serde_json::json!({"received": received})),
        ));
    }
    let linked = {
        let root = state.root.clone();
        let target = target.clone();
        let finished_as = finished_as.clone();
        tokio::task::spawn_blocking(move || -> std::io::Result<bool> {
            if let Some((directory, _)) = target.rsplit_once('/') {
                root.create_dir_all(directory)?;
            }
            // hard_link never replaces an existing file.
            let linked = root.hard_link(&part, &root, &target);
            match linked {
                Ok(()) => {
                    let _ = root.write(resumable_marker(&part), finished_as);
                    let _ = root.remove_file(&part);
                    Ok(true)
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let _ = root.remove_file(&part);
                    Ok(false)
                }
                Err(error) => Err(error),
            }
        })
        .await
        .map_err(|_| ApiError::internal())?
    };
    match linked {
        Ok(true) => {}
        Ok(false) => {
            return Err(ApiError(
                StatusCode::CONFLICT,
                "a file with this name already exists",
            ));
        }
        Err(error) => {
            tracing::warn!("upload: cannot move file into place: {error}");
            return Err(ApiError(
                StatusCode::INSUFFICIENT_STORAGE,
                "server cannot write to the media folder",
            ));
        }
    }
    let scanner = state.clone();
    tokio::spawn(async move {
        let _ = scanner.rescan().await;
    });
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({"path": target, "bytes": received})),
    ))
}

/// A throwaway handle for the "already exists" early return.
fn tempfile_placeholder() -> std::io::Result<std::fs::File> {
    std::fs::File::open(if cfg!(unix) { "/dev/null" } else { "NUL" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn songs_are_looked_up_once_and_again_after_a_while() {
        let media = Media {
            id: "a".repeat(64),
            path: "Musik/A/song.mp3".into(),
            name: "song.mp3".into(),
            kind: "audio".into(),
            title: "Song".into(),
            artist: Some("Artist".into()),
            album: None,
            duration: None,
            bytes: 1,
            modified: 0,
            modified_nanos: 0,
            playback: None,
            album_key: Some("Musik/A".into()),
            album_artist: None,
            track_number: None,
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
        };
        let entry = |found: bool, days: u64| metadata::Entry {
            query: lyrics_query(&media, "Artist"),
            found,
            fetched_at: 1_000_000_000 - days * 86_400,
            value: Value::Null,
        };
        let now = 1_000_000_000;
        // Found before the extra sources: kept. Not found then: looked up again.
        let older = |found: bool| metadata::Entry {
            query: lyrics_query(&media, "Artist").replacen("genius-v2", "genius-v1", 1),
            found,
            fetched_at: now - 86_400,
            value: Value::Null,
        };
        assert!(!needs_lyrics(&media, Some(&older(true)), now));
        assert!(needs_lyrics(&media, Some(&older(false)), now));
        // Matching search results: title without extras, one of the credits, length.
        let mut timed = media.clone();
        timed.title = "God's Plan".into();
        timed.duration = Some(198.9);
        assert!(same_song(
            "God’s Plan",
            "Drake",
            Some(199.0),
            &timed,
            "Drake"
        ));
        assert!(same_song(
            "Gods Plan (Explicit)",
            "Drake, Future",
            None,
            &timed,
            "Drake"
        ));
        assert!(!same_song(
            "God's Plan",
            "Drake",
            Some(240.0),
            &timed,
            "Drake"
        ));
        assert!(!same_song(
            "God's Plan",
            "Cover Band",
            Some(199.0),
            &timed,
            "Drake"
        ));
        assert!(!same_song(
            "Gods Plan Remix",
            "Drake",
            None,
            &timed,
            "Drake"
        ));
        assert!(needs_lyrics(&media, None, now));
        assert!(!needs_lyrics(&media, Some(&entry(true, 100)), now));
        assert!(!needs_lyrics(&media, Some(&entry(false, 3)), now));
        assert!(needs_lyrics(&media, Some(&entry(false, 20)), now));
        let own = Media {
            has_lyrics: true,
            ..media.clone()
        };
        assert!(!needs_lyrics(&own, None, now));
        let video = Media {
            kind: "video".into(),
            ..media.clone()
        };
        assert!(!needs_lyrics(&video, None, now));
        let unknown = Media {
            artist: None,
            ..media.clone()
        };
        assert!(!needs_lyrics(&unknown, None, now));
    }

    #[test]
    fn text_encodings() {
        assert_eq!(decode_text("Grüße".as_bytes()), "Grüße");
        assert_eq!(decode_text(b"\xEF\xBB\xBFHallo"), "Hallo");
        assert_eq!(decode_text(b"Gr\xFC\xDFe"), "Grüße");
        assert_eq!(decode_text(b"\xFF\xFEH\0i\0"), "Hi");
    }

    #[test]
    fn srt_becomes_webvtt() {
        let vtt = to_webvtt("1\n00:00:01,000 --> 00:00:02,500\nHallo, Welt\n");
        assert!(vtt.starts_with("WEBVTT\n\n"));
        assert!(vtt.contains("00:00:01.000 --> 00:00:02.500"));
        assert!(vtt.contains("Hallo, Welt"));
    }

    #[test]
    fn synced_lyrics_detection() {
        assert!(is_synced("[00:01.00] a\n[00:02.00] b\n[00:03.00] c"));
        assert!(!is_synced("Strophe eins\nZeile zwei\n[Refrain]"));
        assert!(!is_synced(
            "[日本語の歌詞です]\n[€uro und mehr]\n[1é: nochmal]"
        ));
    }

    #[test]
    fn upload_paths_are_validated() {
        assert!(upload_target("Musik/Neues Album", "01 Titel.mp3").is_some());
        assert!(upload_target("", "Film.mp4").is_some());
        for (dir, name) in [
            ("Musik/../..", "a.mp3"),
            ("Musik/.versteckt", "a.mp3"),
            ("Musik", ".a.mp3"),
            ("Musik", "a/b.mp3"),
            ("Musik", "ohne-endung"),
            ("Musik", "a\u{0}.mp3"),
            (".miniply-upload", "a.mp3"),
        ] {
            assert!(upload_target(dir, name).is_none(), "{dir}/{name}");
        }
    }
}
