//! Finding music from the app; the download happens on the server.
//!
//! The API only searches the iTunes catalog and files requests in `music-jobs`
//! next to the database. `scripts/musik-suchen.py --dienst` works them off as
//! its own service, because only that service may write to the music folder and
//! run yt-dlp. A request carries a catalog number, never text for a command.
//! Without the `music-jobs` folder, set up by `scripts/setup-musik-dienst.sh`,
//! these routes answer 404.

use crate::{ApiError, AppState, genius::title_key};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use reqwest::Url;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::{
    path::{Path as FilePath, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// The most the catalog returns for one question.
const CATALOG_LIMIT: &str = "200";
const ARTIST_CANDIDATES: &str = "5";
/// How many catalog entries with the same artist name a search joins.
const SAME_NAME_ARTISTS: usize = 3;
/// What an artist page shows at the top.
const ARTIST_LATEST: usize = 5;
const ARTIST_POPULAR: usize = 20;
const ARTIST_RELEASES: usize = 12;
const LISTED_JOBS: usize = 30;
const ACTIVE_JOBS: usize = 50;
/// The service reports every 10 seconds, also during a download.
const SERVICE_SILENCE: Duration = Duration::from_secs(45);
const RESCAN_CHECK: Duration = Duration::from_secs(10);

fn directory(state: &AppState) -> Result<&PathBuf, ApiError> {
    if state.music_jobs.is_dir() {
        Ok(&state.music_jobs)
    } else {
        Err(ApiError::not_found())
    }
}

/// New songs should appear at once, not with the next regular scan.
pub fn spawn(state: AppState) {
    tokio::spawn(async move {
        let marker = state.music_jobs.join("rescan");
        loop {
            tokio::time::sleep(RESCAN_CHECK).await;
            if tokio::fs::remove_file(&marker).await.is_ok() && state.rescan().await.is_err() {
                tracing::error!("library rescan after a music download failed");
            }
        }
    });
}

#[derive(Deserialize)]
pub struct SearchQuery {
    q: String,
    kind: String,
}

/// Album, single or EP, as the catalog marks it in the title.
fn release_type(title: &str) -> &'static str {
    if title.ends_with(" - Single") {
        "single"
    } else if title.ends_with(" - EP") {
        "ep"
    } else {
        "album"
    }
}

fn without_release_type(title: &str) -> &str {
    title
        .strip_suffix(" - Single")
        .or_else(|| title.strip_suffix(" - EP"))
        .unwrap_or(title)
}

/// Only what the list shows, to keep the answer small on mobile data.
fn search_result(item: &Value, kind: &str) -> Option<Value> {
    let (id, title) = if kind == "album" {
        (item.get("collectionId")?, item.get("collectionName")?)
    } else {
        (item.get("trackId")?, item.get("trackName")?)
    };
    let title = title.as_str()?;
    let (title, release) = if kind == "album" {
        (without_release_type(title), Some(release_type(title)))
    } else {
        (title, None)
    };
    let cover = item
        .get("artworkUrl100")
        .and_then(Value::as_str)
        .filter(|cover| {
            cover.parse::<Url>().is_ok_and(|url| {
                url.scheme() == "https"
                    && url
                        .host_str()
                        .is_some_and(|host| host.ends_with(".mzstatic.com"))
            })
        });
    let explicitness = if kind == "album" {
        "collectionExplicitness"
    } else {
        "trackExplicitness"
    };
    Some(json!({
        "id": id.as_u64()?,
        "kind": kind,
        "explicit": has_explicit_words(item, explicitness),
        "title": title,
        "artist": item.get("artistName").and_then(Value::as_str),
        "album": if kind == "song" { item.get("collectionName").and_then(Value::as_str) } else { None },
        "year": item.get("releaseDate").and_then(Value::as_str).and_then(|d| d.get(..4)),
        "released": item.get("releaseDate").and_then(Value::as_str).and_then(|d| d.get(..10)),
        "release_type": release,
        "track_count": if kind == "album" { item.get("trackCount").and_then(Value::as_u64) } else { None },
        "seconds": item.get("trackTimeMillis").and_then(Value::as_u64).map(|ms| ms / 1000),
        "cover": cover,
    }))
}

/// A cleaned catalog entry also has an uncensored original, and that is what gets loaded.
fn has_explicit_words(item: &Value, field: &str) -> bool {
    matches!(
        item.get(field).and_then(Value::as_str),
        Some("explicit" | "cleaned")
    )
}

/// From the local copy of the catalog when it has the answer (see `music_catalog`).
async fn catalog(state: &AppState, url: Url) -> Option<Vec<Value>> {
    crate::music_catalog::catalog(state, url).await
}

fn search_url(words: &str, entity: &str, limit: &str) -> Option<Url> {
    Url::parse_with_params(
        "https://itunes.apple.com/search",
        &[
            ("term", words),
            ("media", "music"),
            ("entity", entity),
            ("limit", limit),
            ("country", "DE"),
        ],
    )
    .ok()
}

/// The artist whose name is exactly what was typed. The word search only finds
/// part of an artist's work, and mostly the censored versions.
pub(crate) async fn exact_artist(state: &AppState, words: &str) -> Option<(u64, String)> {
    if let Some(cache) = state.music_cache.as_ref()
        && let Some(known) = cache.artist(words).await
    {
        return Some(known);
    }
    let url = search_url(words, "musicArtist", ARTIST_CANDIDATES)?;
    let wanted = title_key(words);
    let results = catalog(state, url).await?;
    let found = results.iter().find_map(|item| {
        let name = item.get("artistName")?.as_str()?;
        (title_key(name) == wanted).then_some((item.get("artistId")?.as_u64()?, name.to_owned()))
    })?;
    if let Some(cache) = state.music_cache.as_ref() {
        cache.remember_artist(words, found.0, &found.1).await;
    }
    Some(found)
}

fn credits_artist(item: &Value, artist: &str) -> bool {
    let wanted = title_key(artist);
    item.get("artistName")
        .and_then(Value::as_str)
        .is_some_and(|credit| {
            credit
                .split([',', '&'])
                .any(|name| title_key(name) == wanted)
        })
}

/// An album of someone else with this artist as a guest.
fn names_guest(title: &str) -> bool {
    let lower = title.to_lowercase();
    ["feat.", "ft.", "(with ", "[with ", "{feat", "featuring "]
        .iter()
        .any(|marker| lower.contains(marker))
}

/// Which of several versions to keep: uncensored, from an album, the longest.
fn version_rank(item: &Value, kind: &str) -> (bool, bool, u64) {
    let explicitness = if kind == "album" {
        "collectionExplicitness"
    } else {
        "trackExplicitness"
    };
    let collection = item
        .get("collectionName")
        .and_then(Value::as_str)
        .unwrap_or("");
    (
        item.get(explicitness).and_then(Value::as_str) != Some("cleaned"),
        !collection.ends_with(" - Single"),
        item.get("trackCount").and_then(Value::as_u64).unwrap_or(0),
    )
}

/// From what the catalog answered to what the list shows: real albums under
/// "album", each release once, with `artist` the songs of that artist first.
fn listed_results(items: &[Value], kind: &str, artist: Option<&str>) -> Vec<Value> {
    chosen_items(items, kind, artist)
        .into_iter()
        .filter_map(|item| search_result(item, kind))
        .collect()
}

pub(crate) fn chosen_items<'a>(
    items: &'a [Value],
    kind: &str,
    artist: Option<&str>,
) -> Vec<&'a Value> {
    let name_field = if kind == "album" {
        "collectionName"
    } else {
        "trackName"
    };
    let mut best: Vec<(String, &Value)> = Vec::new();
    for item in items {
        let Some(title) = item.get(name_field).and_then(Value::as_str) else {
            continue;
        };
        if kind == "album"
            && (title.ends_with(" - Single")
                || names_guest(title)
                || artist.is_some_and(|artist| !credits_artist(item, artist)))
        {
            continue;
        }
        let credit = item.get("artistName").and_then(Value::as_str).unwrap_or("");
        let key = format!("{}|{}", title_key(title), title_key(credit));
        match best.iter_mut().find(|(known, _)| *known == key) {
            Some(found) => {
                if version_rank(item, kind) > version_rank(found.1, kind) {
                    found.1 = item;
                }
            }
            None => best.push((key, item)),
        }
    }
    let mut chosen: Vec<&Value> = best.into_iter().map(|(_, item)| item).collect();
    if let Some(artist) = artist {
        if kind == "album" {
            chosen.sort_by_key(|item| {
                std::cmp::Reverse(
                    item.get("releaseDate")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned(),
                )
            });
        } else {
            chosen.sort_by_key(|item| !credits_artist(item, artist));
        }
    }
    chosen
}

fn release_date(item: &Value) -> &str {
    item.get("releaseDate")
        .and_then(Value::as_str)
        .unwrap_or("")
}

/// The catalog lists an artist's songs by popularity. On top comes what is new:
/// albums, and songs that are not part of a listed album.
fn artist_overview(songs: &[Value], albums: &[Value], artist: &str) -> Value {
    let releases = artist_releases(albums, artist);
    let own_songs: Vec<Value> = songs
        .iter()
        .filter(|item| credits_artist(item, artist))
        .cloned()
        .collect();
    let album_items = chosen_items(albums, "album", Some(artist));
    let song_items = chosen_items(&own_songs, "song", Some(artist));
    let album_title = |item: &Value| {
        item.get("collectionName")
            .and_then(Value::as_str)
            .map(title_key)
    };
    let listed_titles: Vec<_> = album_items.iter().filter_map(|i| album_title(i)).collect();
    let mut latest: Vec<(&str, Value)> = album_items
        .iter()
        .filter_map(|item| Some((release_date(item), search_result(item, "album")?)))
        .chain(
            song_items
                .iter()
                .filter(|item| !album_title(item).is_some_and(|t| listed_titles.contains(&t)))
                .filter_map(|item| Some((release_date(item), search_result(item, "song")?))),
        )
        .collect();
    latest.sort_by_key(|(date, _)| std::cmp::Reverse(*date));
    latest.truncate(ARTIST_LATEST);
    let popular: Vec<Value> = song_items
        .iter()
        .filter_map(|item| search_result(item, "song"))
        .take(ARTIST_POPULAR)
        .collect();
    let albums: Vec<Value> = album_items
        .iter()
        .filter_map(|item| search_result(item, "album"))
        .collect();
    let latest: Vec<Value> = latest.into_iter().map(|(_, item)| item).collect();
    let singles: Vec<Value> = releases
        .iter()
        .filter(|item| item.get("release_type").and_then(Value::as_str) != Some("album"))
        .cloned()
        .collect();
    json!({
        "latest": latest,
        "popular": popular,
        "albums": albums,
        "releases": releases.into_iter().take(ARTIST_RELEASES).collect::<Vec<_>>(),
        "singles": singles,
    })
}

/// Albums, singles and EPs of the artist, each once in its fullest version, newest first.
fn artist_releases(albums: &[Value], artist: &str) -> Vec<Value> {
    let mut best: Vec<(String, &Value)> = Vec::new();
    for item in albums {
        let Some(title) = item.get("collectionName").and_then(Value::as_str) else {
            continue;
        };
        if names_guest(title) || !credits_artist(item, artist) {
            continue;
        }
        let key = format!(
            "{}|{}",
            release_type(title),
            title_key(without_release_type(title))
        );
        match best.iter_mut().find(|(known, _)| *known == key) {
            Some(found) => {
                if version_rank(item, "album") > version_rank(found.1, "album") {
                    found.1 = item;
                }
            }
            None => best.push((key, item)),
        }
    }
    let mut chosen: Vec<&Value> = best.into_iter().map(|(_, item)| item).collect();
    chosen.sort_by_key(|item| std::cmp::Reverse(release_date(item).to_owned()));
    chosen
        .into_iter()
        .filter_map(|item| search_result(item, "album"))
        .collect()
}

pub(crate) fn lookup_url(id: u64, entity: &str) -> Option<Url> {
    Url::parse_with_params(
        "https://itunes.apple.com/lookup",
        &[
            ("id", id.to_string().as_str()),
            ("entity", entity),
            ("limit", CATALOG_LIMIT),
            ("country", "DE"),
        ],
    )
    .ok()
}

#[derive(Deserialize)]
pub struct ArtistQuery {
    name: String,
}

pub async fn artist(
    State(state): State<AppState>,
    Query(query): Query<ArtistQuery>,
) -> Result<Json<Value>, ApiError> {
    directory(&state)?;
    let name = query.name.trim();
    if name.is_empty() || name.chars().count() > 120 {
        return Err(ApiError::bad_request("artist name missing or too long"));
    }
    let (id, artist) = exact_artist(&state, name)
        .await
        .ok_or_else(ApiError::not_found)?;
    let songs = lookup_url(id, "song").ok_or_else(unavailable)?;
    let albums = lookup_url(id, "album").ok_or_else(unavailable)?;
    let (songs, albums) = tokio::join!(catalog(&state, songs), catalog(&state, albums));
    let (songs, albums) = songs.zip(albums).ok_or_else(unavailable)?;
    let overview = artist_overview(&songs, &albums, &artist);
    for list in ["latest", "albums"] {
        if let Some(results) = overview.get(list).and_then(Value::as_array) {
            crate::music_catalog::prefetch_albums(album_ids(results));
        }
    }
    Ok(Json(overview))
}

#[derive(Deserialize)]
pub struct PreviewQuery {
    kind: String,
    id: u64,
}

fn is_song(item: &Value) -> bool {
    item.get("wrapperType").and_then(Value::as_str) == Some("track")
        && item.get("kind").and_then(Value::as_str) == Some("song")
}

/// The songs in the order of the release, as the service will load them.
fn preview_tracks(items: &[Value]) -> Vec<Value> {
    let number = |item: &Value, field: &str| item.get(field).and_then(Value::as_u64).unwrap_or(0);
    let mut songs: Vec<&Value> = items.iter().filter(|item| is_song(item)).collect();
    songs.sort_by_key(|item| (number(item, "discNumber"), number(item, "trackNumber")));
    songs
        .into_iter()
        .filter_map(|item| {
            Some(json!({
                "id": item.get("trackId")?.as_u64()?,
                "title": item.get("trackName")?.as_str()?,
                "artist": item.get("artistName").and_then(Value::as_str),
                "seconds": item.get("trackTimeMillis").and_then(Value::as_u64).map(|ms| ms / 1000),
                "explicit": has_explicit_words(item, "trackExplicitness"),
            }))
        })
        .collect()
}

fn find_collection(items: &[Value]) -> Option<&Value> {
    items
        .iter()
        .find(|item| item.get("wrapperType").and_then(Value::as_str) == Some("collection"))
}

/// The uncensored and fullest release with this title, if the artist has one.
fn fullest_release<'a>(item: &'a Value, releases: &'a [Value]) -> &'a Value {
    let title = |value: &Value| {
        value
            .get("collectionName")
            .and_then(Value::as_str)
            .map(title_key)
    };
    releases
        .iter()
        .filter(|other| other.get("collectionId").is_some() && title(other) == title(item))
        .fold(item, |best, other| {
            if version_rank(other, "album") > version_rank(best, "album") {
                other
            } else {
                best
            }
        })
}

fn unavailable() -> ApiError {
    ApiError(StatusCode::BAD_GATEWAY, "music catalog not available")
}

async fn lookup(state: &AppState, id: u64, entity: &str) -> Result<Vec<Value>, ApiError> {
    let url = lookup_url(id, entity).ok_or_else(unavailable)?;
    catalog(state, url).await.ok_or_else(unavailable)
}

/// The track list of an album, from its uncensored and fullest release.
pub(crate) async fn album_preview(state: &AppState, id: u64) -> Result<Value, ApiError> {
    let mut items = lookup(state, id, "song").await?;
    let mut album = find_collection(&items)
        .ok_or_else(ApiError::not_found)?
        .clone();
    if album.get("collectionExplicitness").and_then(Value::as_str) != Some("explicit")
        && let Some(artist) = album.get("artistId").and_then(Value::as_u64)
    {
        let releases = lookup(state, artist, "album").await?;
        let best = fullest_release(&album, &releases).clone();
        let best_id = best.get("collectionId").and_then(Value::as_u64);
        if let Some(best_id) = best_id.filter(|best_id| *best_id != id) {
            items = lookup(state, best_id, "song").await?;
            album = best;
        }
    }
    let item = search_result(&album, "album").ok_or_else(ApiError::not_found)?;
    Ok(json!({ "item": item, "tracks": preview_tracks(&items) }))
}

/// Album numbers in a list answer, for loading their track lists ahead.
fn album_ids(results: &[Value]) -> impl Iterator<Item = u64> + '_ {
    results
        .iter()
        .filter(|item| item.get("kind").and_then(Value::as_str) == Some("album"))
        .filter_map(|item| item.get("id").and_then(Value::as_u64))
}

pub async fn preview(
    State(state): State<AppState>,
    Query(query): Query<PreviewQuery>,
) -> Result<Json<Value>, ApiError> {
    directory(&state)?;
    let lookup = async |id: u64, entity: &str| lookup(&state, id, entity).await;
    match query.kind.as_str() {
        "song" => {
            let items = lookup(query.id, "song").await?;
            let song = items
                .iter()
                .find(|item| {
                    is_song(item) && item.get("trackId").and_then(Value::as_u64) == Some(query.id)
                })
                .ok_or_else(ApiError::not_found)?;
            let item = search_result(song, "song").ok_or_else(ApiError::not_found)?;
            let tracks = preview_tracks(std::slice::from_ref(song));
            Ok(Json(json!({ "item": item, "tracks": tracks })))
        }
        "album" => Ok(Json(album_preview(&state, query.id).await?)),
        _ => Err(ApiError::bad_request("unknown kind")),
    }
}

/// "Skepta - Chiltern Firehouse" as the catalog search wants it: words without dashes,
/// and the part before and after the dash, if there is one.
fn search_words(typed: &str) -> (String, Option<(String, String)>) {
    let typed = typed.replace(['–', '—'], "-");
    let parts = typed
        .split_once(" - ")
        .map(|(left, right)| (left.trim().to_owned(), right.trim().to_owned()))
        .filter(|(left, right)| !left.is_empty() && !right.is_empty());
    let words = typed
        .split(|c: char| c.is_whitespace() || c == '-')
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    (words, parts)
}

/// What to ask when the whole question finds nothing: the title after a dash, then the
/// words with one of the first three left out.
fn fallback_searches(words: &str, parts: Option<&(String, String)>) -> Vec<String> {
    let mut tries = Vec::new();
    if let Some((_, title)) = parts {
        tries.push(search_words(title).0);
    }
    let list: Vec<&str> = words.split(' ').collect();
    if list.len() >= 3 {
        for left_out in 0..3 {
            let rest: Vec<&str> = list
                .iter()
                .enumerate()
                .filter(|(position, _)| *position != left_out)
                .map(|(_, word)| *word)
                .collect();
            tries.push(rest.join(" "));
        }
    }
    tries.dedup();
    tries
}

/// With "artist - title", what matches both comes first.
fn rank_by_parts(results: &mut [Value], parts: Option<&(String, String)>) {
    let Some((artist, title)) = parts else {
        return;
    };
    let (artist, title) = (title_key(artist), title_key(title));
    let has = |item: &Value, field: &str, wanted: &str| {
        item.get(field)
            .and_then(Value::as_str)
            .is_some_and(|value| title_key(value).contains(wanted))
    };
    results.sort_by_key(|item| (!has(item, "title", &title), !has(item, "artist", &artist)));
}

/// Every artist with exactly this name. The catalog sometimes splits one artist into
/// several entries, and a song may sit under the second one.
async fn exact_artists(state: &AppState, words: &str) -> Vec<(u64, String)> {
    let mut found: Vec<(u64, String)> = exact_artist(state, words).await.into_iter().collect();
    if found.is_empty() {
        return found;
    }
    let wanted = title_key(words);
    if let Some(url) = search_url(words, "musicArtist", ARTIST_CANDIDATES)
        && let Some(results) = catalog(state, url).await
    {
        for item in &results {
            let (Some(name), Some(id)) = (
                item.get("artistName").and_then(Value::as_str),
                item.get("artistId").and_then(Value::as_u64),
            ) else {
                continue;
            };
            if title_key(name) == wanted
                && found.iter().all(|(known, _)| *known != id)
                && found.len() < SAME_NAME_ARTISTS
            {
                found.push((id, name.to_owned()));
            }
        }
    }
    found
}

pub async fn search(
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<Value>, ApiError> {
    directory(&state)?;
    let typed = query.q.trim();
    if typed.is_empty() || typed.chars().count() > 120 {
        return Err(ApiError::bad_request("search words missing or too long"));
    }
    let kind = match query.kind.as_str() {
        "album" => "album",
        "song" => "song",
        _ => return Err(ApiError::bad_request("unknown kind")),
    };
    let (words, parts) = search_words(typed);
    if words.is_empty() {
        return Err(ApiError::bad_request("search words missing or too long"));
    }
    // Everything of an artist if the words name one, otherwise a word search.
    // "Artist - Title" always asks for a song or album, even if some artist has that whole name.
    let artists = if parts.is_some() {
        Vec::new()
    } else {
        exact_artists(&state, &words).await
    };
    if let Some((_, artist)) = artists.first() {
        let mut items = Vec::new();
        for (id, _) in &artists {
            if let Some(url) = lookup_url(*id, kind)
                && let Some(found) = catalog(&state, url).await
            {
                items.extend(found);
            }
        }
        let results = listed_results(&items, kind, Some(artist));
        if !results.is_empty() {
            crate::music_catalog::prefetch_albums(album_ids(&results));
            return Ok(Json(json!({ "results": results })));
        }
    }
    let url = search_url(&words, kind, CATALOG_LIMIT).ok_or_else(unavailable)?;
    let items = catalog(&state, url).await.ok_or_else(unavailable)?;
    let mut results = listed_results(&items, kind, None);
    if results.is_empty() {
        for other in fallback_searches(&words, parts.as_ref()) {
            let Some(url) = search_url(&other, kind, CATALOG_LIMIT) else {
                continue;
            };
            if let Some(items) = catalog(&state, url).await {
                results = listed_results(&items, kind, None);
                if !results.is_empty() {
                    break;
                }
            }
        }
    }
    rank_by_parts(&mut results, parts.as_ref());
    crate::music_catalog::prefetch_albums(album_ids(&results));
    Ok(Json(json!({ "results": results })))
}

fn read_json(path: &FilePath) -> Option<Map<String, Value>> {
    match serde_json::from_slice(&std::fs::read(path).ok()?).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// Requests with what the service has reported so far, newest first.
fn read_jobs(directory: &FilePath) -> Vec<Map<String, Value>> {
    let mut jobs: Vec<Map<String, Value>> = std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let id = name.strip_suffix(".json")?;
            if id.ends_with(".state") {
                return None;
            }
            let mut job = read_json(&entry.path())?;
            let state = read_json(&directory.join(format!("{id}.state.json")));
            job.extend(state.unwrap_or_else(|| {
                let queued = json!({"state": "queued", "done": 0, "total": 0, "missing": []});
                match queued {
                    Value::Object(map) => map,
                    _ => Map::new(),
                }
            }));
            Some(job)
        })
        .collect();
    jobs.sort_by_key(|job| {
        std::cmp::Reverse(job.get("created").and_then(Value::as_u64).unwrap_or(0))
    });
    jobs
}

fn is_active(job: &Map<String, Value>) -> bool {
    matches!(
        job.get("state").and_then(Value::as_str),
        Some("queued" | "running")
    )
}

fn service_online(directory: &FilePath) -> bool {
    std::fs::metadata(directory.join("heartbeat"))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|time| time.elapsed().ok())
        .is_some_and(|age| age < SERVICE_SILENCE)
}

pub async fn jobs(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    let directory = directory(&state)?.clone();
    tokio::task::spawn_blocking(move || {
        let mut jobs = read_jobs(&directory);
        jobs.truncate(LISTED_JOBS);
        Json(json!({ "service_online": service_online(&directory), "jobs": jobs }))
    })
    .await
    .map_err(|_| ApiError::internal())
}

#[derive(Deserialize)]
pub struct NewJob {
    pub(crate) kind: String,
    pub(crate) item_id: u64,
    pub(crate) title: String,
    pub(crate) artist: Option<String>,
    pub(crate) cover: Option<String>,
}

/// Every release of an artist, newest first, from a catalog copy at most
/// `fresh` seconds old. Also returns the name as the catalog spells it.
pub(crate) async fn releases_of(
    state: &AppState,
    name: &str,
    fresh: u64,
) -> Option<(String, Vec<Value>)> {
    let (id, artist) = exact_artist(state, name).await?;
    let albums =
        crate::music_catalog::catalog_within(state, lookup_url(id, "album")?, fresh).await?;
    let releases = artist_releases(&albums, &artist);
    Some((artist, releases))
}

/// The music folder for requests, when the music service is set up.
pub(crate) fn jobs_directory(state: &AppState) -> Option<std::path::PathBuf> {
    directory(state).ok().cloned()
}

fn shortened(value: &str) -> String {
    value.chars().take(200).collect()
}

pub async fn create_job(
    State(state): State<AppState>,
    Json(new): Json<NewJob>,
) -> Result<Response, ApiError> {
    let directory = directory(&state)?.clone();
    if !["album", "song"].contains(&new.kind.as_str()) || new.item_id == 0 {
        return Err(ApiError::bad_request("unknown kind or catalog number"));
    }
    tokio::task::spawn_blocking(move || {
        write_job(&directory, new).map(|(status, job)| (status, Json(job)).into_response())
    })
    .await
    .map_err(|_| ApiError::internal())?
}

/// Files a request for the music service, or returns the same one already waiting.
pub(crate) fn write_job(
    directory: &std::path::Path,
    new: NewJob,
) -> Result<(StatusCode, Value), ApiError> {
    {
        let jobs = read_jobs(directory);
        let same = jobs.iter().find(|job| {
            is_active(job)
                && job.get("kind").and_then(Value::as_str) == Some(new.kind.as_str())
                && job.get("item_id").and_then(Value::as_u64) == Some(new.item_id)
        });
        if let Some(same) = same {
            return Ok((StatusCode::OK, Value::Object(same.clone())));
        }
        if jobs.iter().filter(|job| is_active(job)).count() >= ACTIVE_JOBS {
            return Err(ApiError(
                StatusCode::TOO_MANY_REQUESTS,
                "too many waiting music requests",
            ));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ApiError::internal())?
            .as_millis() as u64;
        let job = json!({
            "id": id,
            "kind": new.kind,
            "item_id": new.item_id,
            "title": shortened(&new.title),
            "artist": new.artist.as_deref().map(shortened),
            "cover": new.cover.as_deref().map(shortened),
            "created": created,
            "state": "queued",
            "done": 0,
            "total": 0,
            "missing": [],
        });
        // The service only reads complete files that end in ".json".
        let temporary = directory.join(format!("{id}.new"));
        let data = serde_json::to_vec(&job).map_err(|_| ApiError::internal())?;
        std::fs::write(&temporary, data).map_err(|_| ApiError::internal())?;
        std::fs::rename(&temporary, directory.join(format!("{id}.json")))
            .map_err(|_| ApiError::internal())?;
        Ok((StatusCode::CREATED, job))
    }
}

/// Stops a running request after its current song; otherwise forgets it.
pub async fn delete_job(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let directory = directory(&state)?.clone();
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| ApiError::not_found())?
        .to_string();
    tokio::task::spawn_blocking(move || {
        let request = directory.join(format!("{id}.json"));
        if !request.exists() {
            return Err(ApiError::not_found());
        }
        let status = directory.join(format!("{id}.state.json"));
        let running = read_json(&status)
            .is_some_and(|s| s.get("state").and_then(Value::as_str) == Some("running"));
        if running {
            std::fs::write(directory.join(format!("{id}.cancel")), [])
                .map_err(|_| ApiError::internal())?;
            return Ok(StatusCode::ACCEPTED);
        }
        // The state goes last: without it a leftover request would count as new.
        std::fs::remove_file(&request).map_err(|_| ApiError::internal())?;
        let _ = std::fs::remove_file(&status);
        Ok(StatusCode::NO_CONTENT)
    })
    .await
    .map_err(|_| ApiError::internal())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn results_keep_only_what_the_list_shows() {
        let item = json!({
            "collectionId": 7,
            "collectionName": "Views",
            "artistName": "Drake",
            "releaseDate": "2016-04-29T07:00:00Z",
            "trackCount": 20,
            "artworkUrl100": "https://is1-ssl.mzstatic.com/a/100x100bb.jpg",
            "collectionViewUrl": "https://music.apple.com/x",
        });
        let result = search_result(&item, "album").unwrap();
        assert_eq!(result["id"], 7);
        assert_eq!(result["year"], "2016");
        assert_eq!(result["track_count"], 20);
        assert!(result.get("collectionViewUrl").is_none());
        assert!(search_result(&item, "song").is_none());
    }

    fn album(
        id: u64,
        title: &str,
        artist: &str,
        explicitness: &str,
        tracks: u64,
        date: &str,
    ) -> Value {
        json!({
            "collectionId": id,
            "collectionName": title,
            "artistName": artist,
            "collectionExplicitness": explicitness,
            "trackCount": tracks,
            "releaseDate": date,
        })
    }

    #[test]
    fn albums_of_an_artist_without_singles_and_guest_spots() {
        let items = [
            json!({"wrapperType": "artist", "artistName": "Drake", "artistId": 1}),
            album(1, "Views", "Drake", "cleaned", 21, "2016-01-01"),
            album(2, "Views", "Drake", "explicit", 21, "2016-01-01"),
            album(3, "HABIBTI (FOMO)", "Drake", "cleaned", 15, "2026-01-01"),
            album(4, "HABIBTI (FOMO)", "Drake", "explicit", 24, "2026-01-01"),
            album(
                5,
                "Her Loss",
                "Drake & 21 Savage",
                "explicit",
                16,
                "2022-01-01",
            ),
            album(
                6,
                "Marvins Room - Single",
                "Drake",
                "explicit",
                1,
                "2011-01-01",
            ),
            album(
                7,
                "Work (feat. Drake) [Remixes]",
                "Rihanna",
                "explicit",
                8,
                "2016-01-01",
            ),
            album(8, "We the Best", "DJ Khaled", "explicit", 12, "2017-01-01"),
        ];
        let results = listed_results(&items, "album", Some("Drake"));
        let ids: Vec<_> = results.iter().map(|r| r["id"].as_u64().unwrap()).collect();
        assert_eq!(ids, [4, 5, 2]);
    }

    #[test]
    fn a_word_search_also_leaves_singles_out() {
        let items = [
            album(1, "Views", "Drake", "explicit", 21, "2016-01-01"),
            album(2, "Views - Single", "Someone", "explicit", 1, "2020-01-01"),
        ];
        assert_eq!(listed_results(&items, "album", None).len(), 1);
    }

    #[test]
    fn songs_of_the_artist_come_before_guest_spots_and_from_the_album() {
        let song = |id: u64, title: &str, artist: &str, album: &str| {
            json!({
                "trackId": id,
                "trackName": title,
                "artistName": artist,
                "collectionName": album,
                "trackExplicitness": "explicit",
            })
        };
        let items = [
            song(1, "Work (feat. Drake)", "Rihanna", "Anti"),
            song(
                2,
                "One Dance (feat. Wizkid & Kyla)",
                "Drake",
                "One Dance - Single",
            ),
            song(3, "One Dance (feat. Wizkid & Kyla)", "Drake", "Views"),
        ];
        let results = listed_results(&items, "song", Some("Drake"));
        let ids: Vec<_> = results.iter().map(|r| r["id"].as_u64().unwrap()).collect();
        assert_eq!(ids, [3, 1]);
    }

    #[test]
    fn an_artist_page_starts_with_what_is_new_then_the_popular_songs() {
        let song = |id: u64, title: &str, artist: &str, album: &str, date: &str| {
            json!({
                "trackId": id,
                "trackName": title,
                "artistName": artist,
                "collectionName": album,
                "trackExplicitness": "explicit",
                "releaseDate": date,
            })
        };
        let songs = [
            song(1, "Hit", "Drake", "Views", "2016-01-01"),
            song(2, "Guest", "Rihanna", "Anti", "2026-05-01"),
            song(3, "New Song", "Drake", "New Song - Single", "2026-03-01"),
        ];
        let albums = [
            album(7, "Views", "Drake", "explicit", 20, "2016-01-01"),
            album(8, "Newest", "Drake", "explicit", 12, "2026-01-01"),
        ];
        let overview = artist_overview(&songs, &albums, "Drake");
        let ids = |field: &str| -> Vec<u64> {
            overview[field]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["id"].as_u64().unwrap())
                .collect()
        };
        assert_eq!(ids("latest"), [3, 8, 7]);
        assert_eq!(ids("popular"), [1, 3]);
        assert_eq!(ids("albums"), [8, 7]);
    }

    #[test]
    fn dashes_in_the_search_are_not_words() {
        let (words, parts) = search_words("Skepta - Chiltern Firehouse");
        assert_eq!(words, "Skepta Chiltern Firehouse");
        assert_eq!(parts, Some(("Skepta".into(), "Chiltern Firehouse".into())));
        assert_eq!(search_words("uzi – london").0, "uzi london");
        assert_eq!(search_words("Jay-Z").0, "Jay Z");
        assert_eq!(search_words("fakemink").1, None);
    }

    #[test]
    fn a_search_without_results_tries_fewer_words() {
        let parts = Some(("Skepta".to_owned(), "Chiltern Firehouse".to_owned()));
        let tries = fallback_searches("Skepta Chiltern Firehouse", parts.as_ref());
        assert_eq!(
            tries,
            ["Chiltern Firehouse", "Skepta Firehouse", "Skepta Chiltern"]
        );
        assert!(fallback_searches("uzi london", None).is_empty());
    }

    #[test]
    fn artist_and_title_matches_come_first() {
        let mut results = vec![
            json!({"title": "What You Saying", "artist": "Lil Uzi Vert"}),
            json!({"title": "London (Bonus)", "artist": "Someone Else"}),
            json!({"title": "London (Bonus)", "artist": "Lil Uzi Vert"}),
        ];
        let parts = Some(("uzi".to_owned(), "london".to_owned()));
        rank_by_parts(&mut results, parts.as_ref());
        assert_eq!(results[0]["artist"], "Lil Uzi Vert");
        assert_eq!(results[0]["title"], "London (Bonus)");
        assert_eq!(results[1]["artist"], "Someone Else");
    }

    #[test]
    fn an_artist_page_lists_every_release_and_singles_apart() {
        let albums = [
            album(7, "Views", "Drake", "explicit", 20, "2016-04-29T07:00:00Z"),
            album(9, "Views", "Drake", "cleaned", 20, "2016-04-29T07:00:00Z"),
            album(
                8,
                "Hotline Bling - Single",
                "Drake",
                "explicit",
                1,
                "2015-07-31T07:00:00Z",
            ),
            album(
                10,
                "Scary Hours - EP",
                "Drake",
                "explicit",
                2,
                "2018-01-19T08:00:00Z",
            ),
            album(
                11,
                "Song (feat. Drake) - Single",
                "Someone",
                "explicit",
                1,
                "2020-01-01T08:00:00Z",
            ),
        ];
        let overview = artist_overview(&[], &albums, "Drake");
        let field = |list: &str, key: &str| -> Vec<String> {
            overview[list]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r[key].to_string().trim_matches('"').to_owned())
                .collect()
        };
        assert_eq!(field("releases", "id"), ["10", "7", "8"]);
        assert_eq!(field("releases", "release_type"), ["ep", "album", "single"]);
        assert_eq!(
            field("releases", "title"),
            ["Scary Hours", "Views", "Hotline Bling"]
        );
        assert_eq!(
            field("releases", "released"),
            ["2018-01-19", "2016-04-29", "2015-07-31"]
        );
        assert_eq!(field("singles", "id"), ["10", "8"]);
    }

    #[test]
    fn a_preview_lists_the_songs_in_album_order() {
        let track = |id: u64, disc: u64, number: u64, explicitness: &str| {
            json!({
                "wrapperType": "track",
                "kind": "song",
                "trackId": id,
                "trackName": format!("Song {id}"),
                "discNumber": disc,
                "trackNumber": number,
                "trackTimeMillis": 199_973,
                "trackExplicitness": explicitness,
            })
        };
        let items = [
            json!({"wrapperType": "collection", "collectionId": 1, "collectionName": "A"}),
            track(3, 2, 1, "notExplicit"),
            track(2, 1, 2, "cleaned"),
            track(1, 1, 1, "explicit"),
            json!({"wrapperType": "track", "kind": "music-video", "trackId": 9, "trackName": "Video"}),
        ];
        let tracks = preview_tracks(&items);
        let ids: Vec<_> = tracks.iter().map(|t| t["id"].as_u64().unwrap()).collect();
        assert_eq!(ids, [1, 2, 3]);
        assert_eq!(tracks[0]["seconds"], 199);
        assert_eq!(tracks[0]["explicit"], true);
        assert_eq!(tracks[1]["explicit"], true);
        assert_eq!(tracks[2]["explicit"], false);
    }

    #[test]
    fn a_preview_moves_from_the_censored_release_to_the_original() {
        let cleaned = album(1, "Views", "Drake", "cleaned", 15, "2016-01-01");
        let releases = [
            json!({"wrapperType": "artist", "artistId": 1}),
            cleaned.clone(),
            album(2, "Views", "Drake", "explicit", 20, "2016-01-01"),
            album(3, "Other", "Drake", "explicit", 30, "2016-01-01"),
        ];
        assert_eq!(fullest_release(&cleaned, &releases)["collectionId"], 2);
    }

    #[test]
    fn foreign_cover_addresses_are_dropped() {
        for cover in [
            "http://is1-ssl.mzstatic.com/a.jpg",
            "https://mzstatic.com.example.org/a.jpg",
        ] {
            let item = json!({"trackId": 1, "trackName": "A", "artworkUrl100": cover});
            assert!(search_result(&item, "song").unwrap()["cover"].is_null());
        }
    }
}
