//! Optional online information for albums, artists, tracks, series and films.
//!
//! The server (never the app) asks public, key-free services in the
//! background: the iTunes Search API (album/track details, cover art),
//! Wikipedia (German first, then English descriptions and images) and TVmaze
//! (series, seasons and episode titles), plus MusicBrainz / Cover Art Archive
//! for album covers iTunes does not have, and the album pages of Genius for
//! the order of the songs. Results and downloaded images are
//! cached in SQLite outside the media share, so each item is looked up once.
//! Only names taken from the library (artist, album, title, series name) are
//! sent to these services; no token, path or IP of the iPhone.
//!
//! Disable with `MINIPLY_ONLINE_METADATA=0`.

use crate::{
    AppState,
    catalog::{Catalog, now},
};
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    sync::atomic::Ordering,
    time::{Duration, Instant},
};

const USER_AGENT: &str =
    "Mediaserver/1.0 (+https://mediaserver.minipliy.net; private media server)";
const REQUEST_SPACING: Duration = Duration::from_millis(1100);
const LOOKUPS_PER_PASS: usize = 300;
const MAX_JSON_BYTES: usize = 8 * 1024 * 1024;
const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
const DAY: u64 = 24 * 60 * 60;

#[derive(Clone, Serialize, Deserialize)]
pub struct Entry {
    pub query: String,
    pub found: bool,
    pub fetched_at: u64,
    pub value: Value,
}

pub fn enabled() -> bool {
    !matches!(
        std::env::var("MINIPLY_ONLINE_METADATA")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Series,
    Album,
    Artist,
    Movie,
    Track,
    GeniusAlbum,
}

#[derive(Clone, Debug)]
pub struct Lookup {
    pub key: String,
    pub kind: Kind,
    pub name: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub year: Option<u32>,
}

impl Lookup {
    fn query(&self) -> String {
        // Albums: v2 adds a looser iTunes search and MusicBrainz covers, so
        // albums without a cover are looked up again once. Artists: v2 only takes
        // a Wikipedia article of exactly that name, so "Helmuth" no longer gets
        // "Helmuth Rilling"; every artist is looked up again once.
        let version = match self.kind {
            Kind::Album | Kind::Artist => "v2",
            _ => "v1",
        };
        format!(
            "{version}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
            self.name,
            self.artist.as_deref().unwrap_or(""),
            self.album.as_deref().unwrap_or(""),
            self.year.map(|y| y.to_string()).unwrap_or_default()
        )
    }
}

fn last_component(path: &str) -> &str {
    path.rsplit_once('/').map_or(path, |(_, name)| name)
}

fn file_stem(name: &str) -> &str {
    name.rsplit_once('.').map_or(name, |(stem, _)| stem)
}

fn ignored_artist(name: &str) -> bool {
    matches!(
        name.trim().to_lowercase().as_str(),
        "" | "various artists"
            | "various"
            | "va"
            | "unknown"
            | "unknown artist"
            | "unbekannt"
            | "unbekannter interpret"
            | "diverse"
            | "diverse interpreten"
    )
}

/// Everything in the catalog worth looking up, most visible first.
pub fn wanted(catalog: &Catalog) -> Vec<Lookup> {
    let mut items: Vec<_> = catalog.files.values().collect();
    items.sort_by(|a, b| a.path.cmp(&b.path));
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    let mut push = |lookup: Lookup, result: &mut Vec<Lookup>| {
        if seen.insert(lookup.key.clone()) {
            result.push(lookup);
        }
    };
    for kind in [
        Kind::Series,
        Kind::Album,
        Kind::Artist,
        Kind::Movie,
        Kind::Track,
        Kind::GeniusAlbum,
    ] {
        for media in &items {
            match (kind, media.kind.as_str()) {
                (Kind::Series, "video") => {
                    if let Some(key) = &media.series_key {
                        push(
                            Lookup {
                                key: format!("series:{key}"),
                                kind,
                                name: clean_title(&crate::text::clean(last_component(key))).0,
                                artist: None,
                                album: None,
                                year: clean_title(&crate::text::clean(last_component(key))).1,
                            },
                            &mut result,
                        );
                    }
                }
                (Kind::Album, "audio") => {
                    if let (Some(key), Some(album)) = (&media.album_key, &media.album) {
                        push(
                            Lookup {
                                key: format!("album:{key}"),
                                kind,
                                name: album.clone(),
                                artist: media.album_artist.clone().filter(|a| !ignored_artist(a)),
                                album: None,
                                year: None,
                            },
                            &mut result,
                        );
                    }
                }
                (Kind::Artist, "audio") => {
                    for name in [&media.artist, &media.album_artist]
                        .into_iter()
                        .flatten()
                        .chain(media.featured.iter())
                    {
                        if ignored_artist(name) {
                            continue;
                        }
                        push(
                            Lookup {
                                key: format!("artist:{}", name.trim().to_lowercase()),
                                kind,
                                name: name.trim().to_owned(),
                                artist: None,
                                album: None,
                                year: None,
                            },
                            &mut result,
                        );
                    }
                }
                (Kind::Movie, "video") if media.series_key.is_none() => {
                    let (title, year) = clean_title(&crate::text::clean(file_stem(&media.name)));
                    if !title.is_empty() {
                        push(
                            Lookup {
                                key: format!("movie:{}", media.id),
                                kind,
                                name: title,
                                artist: None,
                                album: None,
                                year,
                            },
                            &mut result,
                        );
                    }
                }
                (Kind::GeniusAlbum, "audio") => {
                    if let (Some(key), Some(album), Some(artist)) = (
                        &media.album_key,
                        &media.album,
                        media.album_artist.as_ref().filter(|a| !ignored_artist(a)),
                    ) {
                        push(
                            Lookup {
                                key: format!("genius-album:{key}"),
                                kind,
                                name: album.clone(),
                                artist: Some(artist.clone()),
                                album: None,
                                year: None,
                            },
                            &mut result,
                        );
                    }
                }
                (Kind::Track, "audio") => {
                    if let Some(artist) = media.artist.as_ref().filter(|a| !ignored_artist(a)) {
                        push(
                            Lookup {
                                key: format!("track:{}", media.id),
                                kind,
                                name: media.title.clone(),
                                artist: Some(artist.clone()),
                                album: media.album.clone(),
                                year: None,
                            },
                            &mut result,
                        );
                    }
                }
                _ => {}
            }
        }
    }
    result
}

fn fresh(entry: &Entry, lookup: &Lookup, current: u64) -> bool {
    let max_age = if entry.found { 180 * DAY } else { 14 * DAY };
    entry.query == lookup.query() && current.saturating_sub(entry.fetched_at) < max_age
}

/// Starts the background worker unless disabled.
pub fn spawn(state: AppState) {
    if !enabled() {
        tracing::info!("online metadata disabled (MINIPLY_ONLINE_METADATA=0)");
        return;
    }
    tokio::spawn(async move {
        let Some(mut fetcher) = Fetcher::new() else {
            tracing::error!("online metadata: HTTP client could not be created");
            return;
        };
        tokio::time::sleep(Duration::from_secs(5)).await;
        loop {
            let wait = match pass(&state, &mut fetcher).await {
                Pass::Done => Duration::from_secs(10 * 60),
                Pass::More => Duration::from_secs(5),
                Pass::Offline => Duration::from_secs(15 * 60),
            };
            tokio::time::sleep(wait).await;
        }
    });
}

enum Pass {
    Done,
    More,
    Offline,
}

async fn pass(state: &AppState, fetcher: &mut Fetcher) -> Pass {
    let wanted = wanted(&*state.catalog.read().await);
    let current = now();
    let todo: Vec<Lookup> = {
        let known = state.metadata.read().await;
        wanted
            .into_iter()
            .filter(|l| !known.get(&l.key).is_some_and(|e| fresh(e, l, current)))
            .collect()
    };
    state.metadata_pending.store(todo.len(), Ordering::Relaxed);
    if todo.is_empty() {
        return Pass::Done;
    }
    tracing::info!(count = todo.len(), "online metadata: looking up new items");
    for lookup in todo.iter().take(LOOKUPS_PER_PASS) {
        let value = match fetch(fetcher, state, lookup).await {
            Ok(value) => value,
            Err(Transient) => {
                tracing::warn!("online metadata: services unreachable, retrying later");
                return Pass::Offline;
            }
        };
        let entry = Entry {
            query: lookup.query(),
            found: value.is_some(),
            fetched_at: now(),
            value: value.unwrap_or(Value::Null),
        };
        if state
            .store
            .save_metadata(lookup.key.clone(), entry.clone())
            .await
            .is_err()
        {
            return Pass::Offline;
        }
        state
            .metadata
            .write()
            .await
            .insert(lookup.key.clone(), entry);
        // Only this worker writes the counter, so load + store is enough.
        let remaining = state.metadata_pending.load(Ordering::Relaxed);
        state
            .metadata_pending
            .store(remaining.saturating_sub(1), Ordering::Relaxed);
    }
    if todo.len() > LOOKUPS_PER_PASS {
        Pass::More
    } else {
        Pass::Done
    }
}

/// Network outage, rate limit or server error: try again later without
/// remembering "not found".
struct Transient;

struct Fetcher {
    client: reqwest::Client,
    last: Option<Instant>,
}

impl Fetcher {
    fn new() -> Option<Self> {
        let client = reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .timeout(Duration::from_secs(20))
            .connect_timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::limited(5))
            .https_only(true)
            .build()
            .ok()?;
        Some(Self { client, last: None })
    }

    async fn pace(&mut self) {
        if let Some(last) = self.last {
            tokio::time::sleep(REQUEST_SPACING.saturating_sub(last.elapsed())).await;
        }
        self.last = Some(Instant::now());
    }

    async fn get(
        &mut self,
        url: Url,
        limit: usize,
    ) -> Result<Option<(String, Vec<u8>)>, Transient> {
        self.pace().await;
        let mut response = self.client.get(url).send().await.map_err(|_| Transient)?;
        let status = response.status();
        if status.as_u16() == 429 || status.is_server_error() {
            return Err(Transient);
        }
        if !status.is_success() {
            return Ok(None);
        }
        if response
            .content_length()
            .is_some_and(|len| len as usize > limit)
        {
            return Ok(None);
        }
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        let mut data = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Transient)? {
            data.extend_from_slice(&chunk);
            if data.len() > limit {
                return Ok(None);
            }
        }
        Ok(Some((content_type, data)))
    }

    async fn json(&mut self, url: Url) -> Result<Option<Value>, Transient> {
        Ok(self
            .get(url, MAX_JSON_BYTES)
            .await?
            .and_then(|(_, data)| serde_json::from_slice(&data).ok()))
    }

    /// Download an image once and keep it in SQLite. Failures are not fatal.
    async fn artwork(&mut self, state: &AppState, url: &str) -> Option<String> {
        let id = format!("web-{}", &hex::encode(Sha256::digest(url.as_bytes()))[..32]);
        if state.store.has_artwork(id.clone()).await.unwrap_or(false) {
            return Some(id);
        }
        let parsed = Url::parse(url).ok().filter(|u| u.scheme() == "https")?;
        let (content_type, data) = self.get(parsed, MAX_IMAGE_BYTES).await.ok()??;
        let content_type = content_type
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_owned();
        if !["image/jpeg", "image/png", "image/webp", "image/gif"].contains(&content_type.as_str())
            || data.is_empty()
        {
            return None;
        }
        state
            .store
            .save_artwork(id.clone(), content_type, data)
            .await
            .ok()?;
        Some(id)
    }
}

fn url(base: &str, params: &[(&str, &str)]) -> Url {
    Url::parse_with_params(base, params).expect("static URL")
}

fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn date_part(value: &Value, key: &str) -> Option<String> {
    text(value, key).map(|d| d.chars().take(10).collect())
}

fn insert(map: &mut Map<String, Value>, key: &str, value: Option<impl Into<Value>>) {
    if let Some(value) = value {
        map.insert(key.into(), value.into());
    }
}

async fn fetch(
    f: &mut Fetcher,
    state: &AppState,
    lookup: &Lookup,
) -> Result<Option<Value>, Transient> {
    match lookup.kind {
        Kind::Album => album(f, state, lookup).await,
        Kind::Artist => artist(f, state, lookup).await,
        Kind::Track => track(f, lookup).await,
        Kind::Series => series(f, state, lookup).await,
        Kind::Movie => movie(f, state, lookup).await,
        Kind::GeniusAlbum => {
            f.pace().await;
            crate::genius::tracklist(
                &f.client,
                lookup.artist.as_deref().unwrap_or(""),
                &lookup.name,
            )
            .await
            .map_err(|_| Transient)
        }
    }
}

async fn itunes(f: &mut Fetcher, term: &str, entity: &str) -> Result<Vec<Value>, Transient> {
    let address = url(
        "https://itunes.apple.com/search",
        &[
            ("term", term),
            ("media", "music"),
            ("entity", entity),
            ("limit", "15"),
            ("country", "DE"),
        ],
    );
    Ok(f.json(address)
        .await?
        .and_then(|v| v.get("results").and_then(Value::as_array).cloned())
        .unwrap_or_default())
}

struct WikiPage {
    title: String,
    short: Option<String>,
    extract: Option<String>,
    url: Option<String>,
    image: Option<String>,
    lang: &'static str,
}

/// Search Wikipedia and return the first page summary accepted by `accept`.
async fn wikipedia(
    f: &mut Fetcher,
    searches: &[(&'static str, String)],
    accept: impl Fn(&WikiPage) -> bool,
) -> Result<Option<WikiPage>, Transient> {
    for (lang, search) in searches {
        let address = url(
            &format!("https://{lang}.wikipedia.org/w/api.php"),
            &[
                ("action", "query"),
                ("list", "search"),
                ("srsearch", search),
                ("srlimit", "2"),
                ("srprop", ""),
                ("format", "json"),
            ],
        );
        let titles: Vec<String> = f
            .json(address)
            .await?
            .and_then(|v| {
                v.pointer("/query/search")
                    .and_then(Value::as_array)
                    .cloned()
            })
            .unwrap_or_default()
            .iter()
            .filter_map(|r| text(r, "title"))
            .collect();
        for title in titles {
            let encoded =
                utf8_percent_encode(&title.replace(' ', "_"), NON_ALPHANUMERIC).to_string();
            let Ok(address) = Url::parse(&format!(
                "https://{lang}.wikipedia.org/api/rest_v1/page/summary/{encoded}"
            )) else {
                continue;
            };
            let Some(summary) = f.json(address).await? else {
                continue;
            };
            if summary.get("type").and_then(Value::as_str) != Some("standard") {
                continue;
            }
            let original = summary.get("originalimage");
            let image = original
                .filter(|o| {
                    o.get("width").and_then(Value::as_u64).unwrap_or(u64::MAX) <= 2500
                        && !text(o, "source").unwrap_or_default().ends_with(".svg")
                })
                .and_then(|o| text(o, "source"))
                .or_else(|| summary.get("thumbnail").and_then(|t| text(t, "source")));
            let page = WikiPage {
                title: text(&summary, "title").unwrap_or(title),
                short: text(&summary, "description"),
                extract: text(&summary, "extract"),
                url: summary
                    .pointer("/content_urls/desktop/page")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                image,
                lang,
            };
            if accept(&page) {
                return Ok(Some(page));
            }
        }
    }
    Ok(None)
}

fn wiki_mentions(page: &WikiPage, words: &[&str]) -> bool {
    let haystack = format!(
        "{} {}",
        page.short.as_deref().unwrap_or(""),
        page.extract
            .as_deref()
            .unwrap_or("")
            .chars()
            .take(400)
            .collect::<String>()
    )
    .to_lowercase();
    words.iter().any(|w| haystack.contains(w))
}

fn add_wiki(map: &mut Map<String, Value>, page: Option<&WikiPage>) {
    if let Some(page) = page {
        insert(map, "description", page.extract.clone());
        insert(map, "short_description", page.short.clone());
        insert(map, "wikipedia_url", page.url.clone());
        map.insert("description_language".into(), page.lang.into());
    }
}

const MUSIC_WORDS: [&str; 22] = [
    "musik",
    "band",
    "sänger",
    "rapper",
    "singer",
    "musician",
    "dj",
    "komponist",
    "composer",
    "songwriter",
    "produzent",
    "producer",
    "duo",
    "group",
    "gruppe",
    "rock",
    "pop",
    "hip-hop",
    "hip hop",
    "rap",
    "metal",
    "jazz",
];

async fn album(f: &mut Fetcher, state: &AppState, l: &Lookup) -> Result<Option<Value>, Transient> {
    let artist = l.artist.as_deref();
    let term = artist.map_or_else(|| l.name.clone(), |a| format!("{a} {}", l.name));
    let matches = |r: &Value, need_artist: bool| {
        let title = text(r, "collectionName").unwrap_or_default();
        let title_ok = similar(&title, &l.name);
        match artist {
            Some(a) if need_artist => {
                title_ok && similar(&text(r, "artistName").unwrap_or_default(), a)
            }
            _ => normalize(&strip_brackets(&title)) == normalize(&strip_brackets(&l.name)),
        }
    };
    let results = itunes(f, &term, "album").await?;
    let mut best = results.iter().find(|r| matches(r, true)).cloned();
    if best.is_none() && artist.is_some() {
        // Folder artist and catalogue artist can differ ("Various Artists",
        // spelling); accept an exact album title match instead.
        let alone = itunes(f, &l.name, "album").await?;
        best = alone
            .iter()
            .find(|r| matches(r, true))
            .or_else(|| alone.iter().find(|r| matches(r, false)))
            .cloned();
    }
    let mut info = Map::new();
    if let Some(r) = best.as_ref() {
        insert(&mut info, "title", text(r, "collectionName"));
        insert(&mut info, "artist", text(r, "artistName"));
        insert(&mut info, "genre", text(r, "primaryGenreName"));
        insert(&mut info, "release_date", date_part(r, "releaseDate"));
        insert(
            &mut info,
            "year",
            date_part(r, "releaseDate").map(|d| d.chars().take(4).collect::<String>()),
        );
        insert(
            &mut info,
            "track_count",
            r.get("trackCount").and_then(Value::as_u64),
        );
        insert(&mut info, "copyright", text(r, "copyright"));
        if let Some(cover) = text(r, "artworkUrl100") {
            let large = cover.replace("100x100bb", "600x600bb");
            insert(&mut info, "artwork", f.artwork(state, &large).await);
        }
    }
    let by = artist.unwrap_or("");
    let page = wikipedia(
        f,
        &[
            ("de", format!("{} {by} Album", l.name)),
            ("en", format!("{} {by} album", l.name)),
        ],
        |p| {
            similar(&p.title, &l.name)
                && wiki_mentions(
                    p,
                    &[
                        "album",
                        "ep",
                        "single",
                        "soundtrack",
                        "mixtape",
                        "kompilation",
                        "compilation",
                    ],
                )
        },
    )
    .await?;
    add_wiki(&mut info, page.as_ref());
    if !info.contains_key("artwork")
        && let Some(cover) = musicbrainz_cover(f, state, &l.name, artist).await?
    {
        info.insert("artwork".into(), cover.into());
    }
    if !info.contains_key("artwork")
        && let Some(image) = page.as_ref().and_then(|p| p.image.clone())
    {
        insert(&mut info, "artwork", f.artwork(state, &image).await);
    }
    Ok((!info.is_empty()).then_some(Value::Object(info)))
}

fn lucene_phrase(value: &str) -> String {
    let escaped: String = value
        .chars()
        .flat_map(|c| match c {
            '"' | '\\' => vec!['\\', c],
            _ => vec![c],
        })
        .collect();
    format!("\"{escaped}\"")
}

/// Front cover from the Cover Art Archive for a MusicBrainz release group.
async fn musicbrainz_cover(
    f: &mut Fetcher,
    state: &AppState,
    album: &str,
    artist: Option<&str>,
) -> Result<Option<String>, Transient> {
    let mut query = format!("releasegroup:{}", lucene_phrase(album));
    if let Some(artist) = artist {
        query.push_str(&format!(" AND artist:{}", lucene_phrase(artist)));
    }
    let address = url(
        "https://musicbrainz.org/ws/2/release-group/",
        &[("query", query.as_str()), ("fmt", "json"), ("limit", "5")],
    );
    let groups = f
        .json(address)
        .await?
        .and_then(|v| v.get("release-groups").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    for group in groups {
        let score = group.get("score").and_then(Value::as_u64).unwrap_or(0);
        let title = text(&group, "title").unwrap_or_default();
        let credited = group
            .pointer("/artist-credit/0/name")
            .and_then(Value::as_str)
            .unwrap_or("");
        if score < 85 || !similar(&title, album) || artist.is_some_and(|a| !similar(credited, a)) {
            continue;
        }
        let Some(id) = text(&group, "id")
            .filter(|id| id.len() == 36 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
        else {
            continue;
        };
        if let Some(cover) = f
            .artwork(
                state,
                &format!("https://coverartarchive.org/release-group/{id}/front-500"),
            )
            .await
        {
            return Ok(Some(cover));
        }
    }
    Ok(None)
}

async fn artist(f: &mut Fetcher, state: &AppState, l: &Lookup) -> Result<Option<Value>, Transient> {
    let mut info = Map::new();
    let results = itunes(f, &l.name, "musicArtist").await?;
    if let Some(r) = results
        .iter()
        .find(|r| normalize(&text(r, "artistName").unwrap_or_default()) == normalize(&l.name))
    {
        insert(&mut info, "genre", text(r, "primaryGenreName"));
    }
    let page = wikipedia(
        f,
        &[
            ("de", format!("{} Musik", l.name)),
            ("en", format!("{} musician band", l.name)),
        ],
        |p| same_name(&p.title, &l.name) && wiki_mentions(p, &MUSIC_WORDS),
    )
    .await?;
    add_wiki(&mut info, page.as_ref());
    if let Some(image) = page.as_ref().and_then(|p| p.image.clone()) {
        insert(&mut info, "image", f.artwork(state, &image).await);
    }
    Ok((!info.is_empty()).then_some(Value::Object(info)))
}

async fn track(f: &mut Fetcher, l: &Lookup) -> Result<Option<Value>, Transient> {
    let Some(artist) = l.artist.as_deref() else {
        return Ok(None);
    };
    let results = itunes(f, &format!("{artist} {}", l.name), "song").await?;
    let Some(r) = results.iter().find(|r| {
        similar(&text(r, "trackName").unwrap_or_default(), &l.name)
            && similar(&text(r, "artistName").unwrap_or_default(), artist)
    }) else {
        return Ok(None);
    };
    let mut info = Map::new();
    insert(&mut info, "title", text(r, "trackName"));
    insert(&mut info, "artist", text(r, "artistName"));
    insert(&mut info, "album", text(r, "collectionName"));
    insert(&mut info, "genre", text(r, "primaryGenreName"));
    insert(&mut info, "release_date", date_part(r, "releaseDate"));
    insert(
        &mut info,
        "year",
        date_part(r, "releaseDate").map(|d| d.chars().take(4).collect::<String>()),
    );
    insert(
        &mut info,
        "track_number",
        r.get("trackNumber").and_then(Value::as_u64),
    );
    insert(
        &mut info,
        "track_count",
        r.get("trackCount").and_then(Value::as_u64),
    );
    insert(
        &mut info,
        "disc_number",
        r.get("discNumber").and_then(Value::as_u64),
    );
    insert(
        &mut info,
        "explicit",
        text(r, "trackExplicitness").map(|e| e == "explicit"),
    );
    Ok(Some(Value::Object(info)))
}

async fn series(f: &mut Fetcher, state: &AppState, l: &Lookup) -> Result<Option<Value>, Transient> {
    let address = url(
        "https://api.tvmaze.com/singlesearch/shows",
        &[("q", &l.name), ("embed", "episodes")],
    );
    let show = f
        .json(address)
        .await?
        .filter(|s| similar(&text(s, "name").unwrap_or_default(), &l.name));
    let mut info = Map::new();
    if let Some(show) = &show {
        insert(&mut info, "name", text(show, "name"));
        insert(
            &mut info,
            "summary",
            text(show, "summary").map(|s| strip_html(&s)),
        );
        insert(
            &mut info,
            "genres",
            show.get("genres")
                .filter(|g| g.as_array().is_some_and(|a| !a.is_empty()))
                .cloned(),
        );
        insert(&mut info, "premiered", text(show, "premiered"));
        insert(&mut info, "ended", text(show, "ended"));
        insert(&mut info, "status", text(show, "status"));
        insert(
            &mut info,
            "network",
            show.get("network")
                .and_then(|n| text(n, "name"))
                .or_else(|| show.get("webChannel").and_then(|n| text(n, "name"))),
        );
        insert(
            &mut info,
            "rating",
            show.pointer("/rating/average").and_then(Value::as_f64),
        );
        insert(
            &mut info,
            "runtime",
            show.get("averageRuntime")
                .and_then(Value::as_u64)
                .or_else(|| show.get("runtime").and_then(Value::as_u64)),
        );
        insert(&mut info, "tvmaze_url", text(show, "url"));
        let episodes: Vec<Value> = show
            .pointer("/_embedded/episodes")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|e| {
                        let season = e.get("season").and_then(Value::as_u64)?;
                        let number = e.get("number").and_then(Value::as_u64)?;
                        let mut episode = Map::new();
                        episode.insert("season".into(), season.into());
                        episode.insert("number".into(), number.into());
                        insert(&mut episode, "name", text(e, "name"));
                        insert(&mut episode, "airdate", text(e, "airdate"));
                        insert(
                            &mut episode,
                            "runtime",
                            e.get("runtime").and_then(Value::as_u64),
                        );
                        insert(
                            &mut episode,
                            "summary",
                            text(e, "summary").map(|s| truncate(&strip_html(&s), 700)),
                        );
                        Some(Value::Object(episode))
                    })
                    .collect()
            })
            .unwrap_or_default();
        if !episodes.is_empty() {
            info.insert("episodes".into(), Value::Array(episodes));
        }
        if let Some(poster) = show.pointer("/image/original").and_then(Value::as_str) {
            insert(&mut info, "poster", f.artwork(state, poster).await);
        }
    }
    let page = wikipedia(f, &[("de", format!("{} Fernsehserie", l.name))], |p| {
        similar(&p.title, &l.name) && wiki_mentions(p, &["serie", "sitcom", "series", "show"])
    })
    .await?;
    add_wiki(&mut info, page.as_ref());
    if !info.contains_key("poster")
        && let Some(image) = page.as_ref().and_then(|p| p.image.clone())
    {
        insert(&mut info, "poster", f.artwork(state, &image).await);
    }
    Ok((!info.is_empty()).then_some(Value::Object(info)))
}

async fn movie(f: &mut Fetcher, state: &AppState, l: &Lookup) -> Result<Option<Value>, Transient> {
    let year = l.year.map(|y| y.to_string()).unwrap_or_default();
    let page = wikipedia(
        f,
        &[
            ("de", format!("{} {year} Film", l.name)),
            ("en", format!("{} {year} film", l.name)),
        ],
        |p| {
            similar(&p.title, &l.name)
                && wiki_mentions(p, &["film", "movie"])
                && (year.is_empty() || wiki_mentions(p, &[year.as_str()]))
        },
    )
    .await?;
    let Some(page) = page else { return Ok(None) };
    let mut info = Map::new();
    info.insert("title".into(), page.title.clone().into());
    insert(&mut info, "year", l.year);
    add_wiki(&mut info, Some(&page));
    if let Some(image) = page.image.clone() {
        insert(&mut info, "poster", f.artwork(state, &image).await);
    }
    Ok(Some(Value::Object(info)))
}

/// Lower-case letters and digits only.
pub fn normalize(value: &str) -> String {
    value
        .to_lowercase()
        .replace('&', "and")
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn strip_brackets(value: &str) -> String {
    let mut out = String::new();
    let mut depth = 0usize;
    for c in value.chars() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

/// Same name ignoring case, punctuation, bracketed suffixes such as
/// "(Deluxe Edition)" and a leading "The".
/// The same name, apart from a note in brackets ("Drake (Musiker)") and a leading "The".
fn same_name(a: &str, b: &str) -> bool {
    let clean = |s: &str| {
        let n = normalize(&strip_brackets(s));
        n.strip_prefix("the")
            .filter(|r| r.len() >= 3)
            .map(str::to_owned)
            .unwrap_or(n)
    };
    let (a, b) = (clean(a), clean(b));
    !a.is_empty() && a == b
}

pub fn similar(a: &str, b: &str) -> bool {
    let clean = |s: &str| {
        let n = normalize(&strip_brackets(s));
        n.strip_prefix("the")
            .filter(|r| r.len() >= 3)
            .map(str::to_owned)
            .unwrap_or(n)
    };
    let (a, b) = (clean(a), clean(b));
    if a.is_empty() || b.is_empty() {
        return false;
    }
    if a == b {
        return true;
    }
    let (short, long) = if a.len() <= b.len() {
        (&a, &b)
    } else {
        (&b, &a)
    };
    short.chars().count() >= 4 && long.starts_with(short.as_str())
}

/// Readable title and year from a file name such as
/// "The.Matrix.1999.1080p.BluRay.x264" -> ("The Matrix", Some(1999)).
pub fn clean_title(stem: &str) -> (String, Option<u32>) {
    const STOP: [&str; 24] = [
        "1080p", "720p", "2160p", "480p", "4k", "uhd", "bluray", "blu", "bdrip", "brrip", "webrip",
        "web", "webdl", "hdtv", "dvdrip", "x264", "x265", "h264", "h265", "hevc", "german", "dl",
        "remux", "hdr",
    ];
    let spaced: String = stem
        .chars()
        .map(|c| if c == '.' || c == '_' { ' ' } else { c })
        .collect();
    let mut words = Vec::new();
    let mut year = None;
    for (index, raw) in spaced.split_whitespace().enumerate() {
        let bare = raw.trim_matches(|c: char| "()[]{}".contains(c));
        let lower = bare.to_lowercase().replace('-', "");
        if index > 0
            && bare.len() == 4
            && let Ok(value) = bare.parse::<u32>()
            && (1900..=2099).contains(&value)
        {
            year = Some(value);
            break;
        }
        if STOP.contains(&lower.as_str()) || raw.starts_with('[') {
            break;
        }
        words.push(raw);
    }
    let title = words
        .join(" ")
        .trim_matches(|c: char| c == '-' || c == ' ')
        .to_owned();
    (title, year)
}

pub fn strip_html(value: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in value.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .trim()
        .to_owned()
}

fn truncate(value: &str, max: usize) -> String {
    if value.chars().count() <= max {
        return value.to_owned();
    }
    let mut out: String = value.chars().take(max).collect();
    out.push('…');
    out
}

/// JSON for `/v1/metadata`, grouped by kind. Every group is a list of
/// objects with a `key`, so clients never treat paths as JSON object keys.
pub async fn snapshot(state: &AppState) -> Value {
    let mut covers: Vec<Value> = state
        .catalog
        .read()
        .await
        .covers
        .iter()
        .map(|(directory, artwork)| json!({"directory": directory, "artwork": artwork}))
        .collect();
    covers.sort_by(|a, b| a["directory"].as_str().cmp(&b["directory"].as_str()));
    let mut thumbnails: Vec<String> = state.thumbnails.read().await.iter().cloned().collect();
    thumbnails.sort();
    let known = state.metadata.read().await;
    let mut groups: [(&str, Vec<Value>); 5] = [
        ("album", Vec::new()),
        ("artist", Vec::new()),
        ("track", Vec::new()),
        ("series", Vec::new()),
        ("movie", Vec::new()),
    ];
    let mut keys: Vec<_> = known.keys().collect();
    keys.sort();
    for key in keys {
        let entry = &known[key];
        if !entry.found {
            continue;
        }
        if let Some((kind, rest)) = key.split_once(':')
            && let Some((_, list)) = groups.iter_mut().find(|(name, _)| *name == kind)
            && let Value::Object(mut object) = entry.value.clone()
        {
            object.insert("key".into(), rest.into());
            list.push(Value::Object(object));
        }
    }
    let [albums, artists, tracks, series, movies] = groups.map(|(_, list)| Value::Array(list));
    json!({
        "enabled": enabled(),
        "pending": state.metadata_pending.load(Ordering::Relaxed),
        "covers": covers,
        "thumbnails": thumbnails,
        "albums": albums,
        "artists": artists,
        "tracks": tracks,
        "series": series,
        "movies": movies,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_from_release_names() {
        assert_eq!(
            clean_title("The.Matrix.1999.1080p.BluRay.x264"),
            ("The Matrix".into(), Some(1999))
        );
        assert_eq!(
            clean_title("Inception (2010)"),
            ("Inception".into(), Some(2010))
        );
        assert_eq!(
            clean_title("Mein Urlaubsvideo"),
            ("Mein Urlaubsvideo".into(), None)
        );
        assert_eq!(clean_title("2012 (2009)"), ("2012".into(), Some(2009)));
        assert_eq!(
            clean_title("Two and a Half Men"),
            ("Two and a Half Men".into(), None)
        );
    }

    #[test]
    fn fuzzy_names() {
        assert!(similar("Hybrid Theory (Bonus Edition)", "hybrid theory"));
        assert!(similar("The Beatles", "Beatles"));
        assert!(similar("Simon & Garfunkel", "Simon and Garfunkel"));
        assert!(similar("Two and a Half Men", "two and a half men"));
        assert!(!similar("Up", "Upside Down"));
        assert!(!similar("Metallica", "Megadeth"));
    }

    #[test]
    fn musicbrainz_queries_are_quoted() {
        assert_eq!(lucene_phrase("Hybrid Theory"), "\"Hybrid Theory\"");
        assert_eq!(lucene_phrase("Say \"Hi\""), "\"Say \\\"Hi\\\"\"");
    }

    #[test]
    fn an_artist_needs_a_wikipedia_article_of_exactly_that_name() {
        assert!(!same_name("Helmuth Rilling", "Helmuth"));
        assert!(same_name("Drake (Musiker)", "Drake"));
        assert!(same_name("The Weeknd", "Weeknd"));
    }

    #[test]
    fn album_lookups_use_a_new_query_version() {
        let album = Lookup {
            key: "album:x".into(),
            kind: Kind::Album,
            name: "A".into(),
            artist: None,
            album: None,
            year: None,
        };
        let series = Lookup {
            kind: Kind::Series,
            ..album.clone()
        };
        assert!(album.query().starts_with("v2"));
        assert!(series.query().starts_with("v1"));
    }

    #[test]
    fn html_is_removed() {
        assert_eq!(
            strip_html("<p><b>Charlie</b> &amp; Alan&#39;s house</p>"),
            "Charlie & Alan's house"
        );
    }
}
