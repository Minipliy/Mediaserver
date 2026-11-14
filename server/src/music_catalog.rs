//! A local copy of the iTunes catalog for the music search, so that searching an
//! artist answers from the Pi instead of asking Apple every time.
//!
//! Every catalog answer the search needs is kept (only the fields the search
//! uses), lookups for 30 days, word searches for 7. In the background the server
//! fills the copy ahead of time with the songs and albums of the most popular
//! artists: a list ranked by fans on Deezer, seeded from the Deezer charts, the
//! ListenBrainz sitewide statistics and the Apple Music charts. A second pass
//! adds the track list of each of their albums. Covers are not stored; the
//! iPhone loads them from Apple's image servers.
//!
//! Apple allows about 20 requests a minute, so the background pauses while
//! someone uses the search, and albums a search or artist page shows get their
//! track list loaded right away, before they are tapped.
//!
//! Only names and catalog numbers leave the Pi. Switch off with
//! `MINIPLY_MUSIC_CATALOG=0`; the size limit is `MINIPLY_MUSIC_CATALOG_BYTES`
//! (5 GB by default). The copy lives in its own database next to the main one.

use crate::{AppState, catalog::now, genius::title_key};
use reqwest::Url;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value};
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::sync::mpsc;

pub const DEFAULT_ARTISTS: usize = 5000;
const DEFAULT_LIMIT_BYTES: u64 = 5_000_000_000;
const LOOKUP_DAYS: u64 = 30;
const SEARCH_DAYS: u64 = 7;
const LIST_DAYS: u64 = 30;
/// Apple allows about 20 catalog requests a minute.
const APPLE_PAUSE: Duration = Duration::from_millis(3500);
/// Track lists loaded ahead for what a search shows: a few, one after another.
const PREFETCH_PAUSE: Duration = Duration::from_millis(1500);
const PREFETCH_ALBUMS: usize = 6;
const PREFETCH_QUEUE: usize = 24;
/// The background waits this long after the last request from the app.
const USER_QUIET_SECONDS: u64 = 20;
/// Deezer allows 50 requests in 5 seconds.
const DEEZER_PAUSE: Duration = Duration::from_millis(150);
/// How many more candidates than wanted to collect before ranking.
const CANDIDATE_FACTOR: usize = 2;
const SKIPPED_GENRES: [u64; 2] = [457, 95]; // audiobooks, kids
const CHART_COUNTRIES: [&str; 8] = ["de", "us", "gb", "fr", "at", "ch", "ca", "au"];
const LISTENBRAINZ_RANGES: [&str; 4] = ["all_time", "year", "quarter", "month"];
/// What the music search reads from a catalog entry.
const KEPT_FIELDS: [&str; 18] = [
    "wrapperType",
    "kind",
    "artistId",
    "collectionId",
    "trackId",
    "artistName",
    "collectionName",
    "trackName",
    "collectionExplicitness",
    "trackExplicitness",
    "artworkUrl100",
    "trackCount",
    "discNumber",
    "trackNumber",
    "trackTimeMillis",
    "releaseDate",
    "collectionType",
    "primaryGenreName",
];

/// Who asks Apple: the app (at once), loading ahead (shortly paced) or the
/// background copy (paced, and only while the app is quiet).
#[derive(Clone, Copy, PartialEq)]
enum Asker {
    Ahead,
    Background,
}

tokio::task_local! {
    static ASKER: Asker;
}

/// When the app last made the server ask Apple, in seconds since 1970.
static LAST_USER_REQUEST: AtomicU64 = AtomicU64::new(0);
static PREFETCH: OnceLock<mpsc::Sender<u64>> = OnceLock::new();

fn asker() -> Option<Asker> {
    ASKER.try_with(|asker| *asker).ok()
}

/// The background waits while the app is in use.
async fn wait_for_quiet() {
    while now().saturating_sub(LAST_USER_REQUEST.load(Ordering::Relaxed)) < USER_QUIET_SECONDS {
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

/// Loads the track lists of the first albums of a list in the background.
pub fn prefetch_albums(ids: impl IntoIterator<Item = u64>) {
    let Some(queue) = PREFETCH.get() else {
        return;
    };
    for id in ids.into_iter().take(PREFETCH_ALBUMS) {
        // A full queue means a lot is already coming; the rest can wait for a tap.
        if queue.try_send(id).is_err() {
            break;
        }
    }
}

#[derive(Clone)]
pub struct Cache(Arc<Mutex<Connection>>);

impl Cache {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let db = Connection::open(path)?;
        db.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS responses (url TEXT PRIMARY KEY, body TEXT NOT NULL, fetched INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS artists (key TEXT PRIMARY KEY, name TEXT NOT NULL, fans INTEGER NOT NULL,
                 rank INTEGER, apple_id INTEGER, apple_name TEXT, fetched INTEGER);
             CREATE INDEX IF NOT EXISTS artists_rank ON artists (rank);
             CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);",
        )?;
        // Added later: when the track lists of an artist's albums were loaded.
        if db.prepare("SELECT tracks FROM artists LIMIT 0").is_err() {
            db.execute_batch("ALTER TABLE artists ADD COLUMN tracks INTEGER")?;
        }
        Ok(Self(Arc::new(Mutex::new(db))))
    }

    async fn run<T: Send + 'static>(
        &self,
        action: impl FnOnce(&Connection) -> rusqlite::Result<T> + Send + 'static,
    ) -> Option<T> {
        let this = self.clone();
        tokio::task::spawn_blocking(move || {
            let guard = this.0.lock().ok()?;
            action(&guard)
                .map_err(|e| tracing::error!("music catalog: {e}"))
                .ok()
        })
        .await
        .ok()
        .flatten()
    }

    /// The kept answer and its age in seconds.
    async fn response(&self, url: String) -> Option<(Vec<Value>, u64)> {
        let (body, fetched): (String, u64) = self
            .run(move |db| {
                db.query_row(
                    "SELECT body, fetched FROM responses WHERE url = ?1",
                    params![url],
                    |row| Ok((row.get(0)?, row.get::<_, i64>(1)? as u64)),
                )
                .optional()
            })
            .await??;
        Some((
            serde_json::from_str(&body).ok()?,
            now().saturating_sub(fetched),
        ))
    }

    async fn keep(&self, url: String, items: &[Value]) {
        let body = Value::Array(items.iter().map(trimmed).collect()).to_string();
        self.run(move |db| {
            db.execute(
                "INSERT OR REPLACE INTO responses (url, body, fetched) VALUES (?1, ?2, ?3)",
                params![url, body, now() as i64],
            )
        })
        .await;
    }

    /// The catalog number of an artist whose name was typed, if known.
    pub async fn artist(&self, words: &str) -> Option<(u64, String)> {
        let key = title_key(words);
        self.run(move |db| {
            db.query_row(
                "SELECT apple_id, apple_name FROM artists WHERE key = ?1 AND apple_id IS NOT NULL",
                params![key],
                |row| Ok((row.get::<_, i64>(0)? as u64, row.get::<_, String>(1)?)),
            )
            .optional()
        })
        .await
        .flatten()
    }

    pub async fn remember_artist(&self, words: &str, id: u64, name: &str) {
        let (key, name) = (title_key(words), name.to_owned());
        self.run(move |db| {
            db.execute(
                "INSERT INTO artists (key, name, fans, apple_id, apple_name) VALUES (?1, ?2, 0, ?3, ?2)
                 ON CONFLICT(key) DO UPDATE SET apple_id = ?3, apple_name = ?2",
                params![key, name, id as i64],
            )
        })
        .await;
    }

    /// The size of the database file. Summing every stored answer would read
    /// all of them and hold up the search meanwhile.
    pub async fn bytes(&self) -> u64 {
        self.run(|db| {
            db.query_row(
                "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()",
                [],
                |row| row.get::<_, i64>(0),
            )
        })
        .await
        .unwrap_or(0) as u64
    }

    /// How far the copy is: artists with songs, artists on the list.
    pub async fn progress(&self) -> (u64, u64) {
        self.run(|db| {
            db.query_row(
                "SELECT COUNT(fetched), COUNT(rank) FROM artists WHERE rank IS NOT NULL",
                [],
                |row| Ok((row.get::<_, i64>(0)? as u64, row.get::<_, i64>(1)? as u64)),
            )
        })
        .await
        .unwrap_or((0, 0))
    }

    async fn meta(&self, key: &'static str) -> Option<u64> {
        self.run(move |db| {
            db.query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![key],
                |row| row.get::<_, i64>(0),
            )
            .optional()
        })
        .await
        .flatten()
        .map(|v| v as u64)
    }

    async fn set_meta(&self, key: &'static str, value: u64) {
        self.run(move |db| {
            db.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
                params![key, value as i64],
            )
        })
        .await;
    }

    /// The new ranking replaces the old one; known catalog numbers stay.
    async fn save_ranking(&self, ranked: Vec<(String, u64)>) {
        self.run(move |db| {
            let transaction = db.unchecked_transaction()?;
            transaction.execute("UPDATE artists SET rank = NULL", [])?;
            {
                let mut stmt = transaction.prepare(
                    "INSERT INTO artists (key, name, fans, rank) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(key) DO UPDATE SET name = ?2, fans = ?3, rank = ?4",
                )?;
                for (rank, (name, fans)) in ranked.iter().enumerate() {
                    stmt.execute(params![title_key(name), name, *fans as i64, rank as i64])?;
                }
            }
            transaction.commit()
        })
        .await;
    }

    /// The most popular artist whose copy is missing or old.
    async fn next_artist(&self) -> Option<String> {
        let stale = now().saturating_sub(LOOKUP_DAYS * 86_400) as i64;
        self.run(move |db| {
            db.query_row(
                "SELECT name FROM artists WHERE rank IS NOT NULL AND (fetched IS NULL OR fetched < ?1)
                 ORDER BY rank LIMIT 1",
                params![stale],
                |row| row.get::<_, String>(0),
            )
            .optional()
        })
        .await
        .flatten()
    }

    /// The most popular artist with songs whose album track lists are missing or old.
    async fn next_tracks(&self) -> Option<(String, u64)> {
        let stale = now().saturating_sub(LOOKUP_DAYS * 86_400) as i64;
        self.run(move |db| {
            db.query_row(
                "SELECT apple_name, apple_id FROM artists WHERE rank IS NOT NULL AND apple_id IS NOT NULL
                 AND (tracks IS NULL OR tracks < ?1) ORDER BY rank LIMIT 1",
                params![stale],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64)),
            )
            .optional()
        })
        .await
        .flatten()
    }

    async fn mark_tracks(&self, apple_id: u64) {
        self.run(move |db| {
            db.execute(
                "UPDATE artists SET tracks = ?2 WHERE apple_id = ?1",
                params![apple_id as i64, now() as i64],
            )
        })
        .await;
    }

    async fn mark_fetched(&self, name: String, apple: Option<(u64, String)>) {
        self.run(move |db| {
            let (id, apple_name) = apple.map_or((None, None), |(id, n)| (Some(id as i64), Some(n)));
            db.execute(
                "UPDATE artists SET fetched = ?2, apple_id = COALESCE(?3, apple_id),
                 apple_name = COALESCE(?4, apple_name) WHERE key = ?1",
                params![title_key(&name), now() as i64, id, apple_name],
            )
        })
        .await;
    }
}

fn trimmed(item: &Value) -> Value {
    let Some(fields) = item.as_object() else {
        return item.clone();
    };
    let kept: Map<String, Value> = fields
        .iter()
        .filter(|(key, _)| KEPT_FIELDS.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    Value::Object(kept)
}

fn fresh_for(url: &Url) -> u64 {
    if url.path().ends_with("/lookup") {
        LOOKUP_DAYS * 86_400
    } else {
        SEARCH_DAYS * 86_400
    }
}

async fn fetch(state: &AppState, url: Url) -> Option<Vec<Value>> {
    let response = state.http.get(url).send().await.ok()?;
    let data = response.error_for_status().ok()?.bytes().await.ok()?;
    let body: Value = serde_json::from_slice(&data).ok()?;
    body.get("results")?.as_array().cloned()
}

/// A catalog answer: from the copy while it is fresh, otherwise from Apple, and
/// the old copy when Apple does not answer.
pub async fn catalog(state: &AppState, url: Url) -> Option<Vec<Value>> {
    let Some(cache) = state.music_cache.as_ref() else {
        return fetch(state, url).await;
    };
    let key = url.to_string();
    let kept = cache.response(key.clone()).await;
    if let Some((items, age)) = &kept
        && *age < fresh_for(&url)
    {
        return Some(items.clone());
    }
    let asker = asker();
    match asker {
        None => LAST_USER_REQUEST.store(now(), Ordering::Relaxed),
        Some(Asker::Background) => wait_for_quiet().await,
        Some(Asker::Ahead) => {}
    }
    let answer = fetch(state, url).await;
    match asker {
        Some(Asker::Background) => tokio::time::sleep(APPLE_PAUSE).await,
        Some(Asker::Ahead) => tokio::time::sleep(PREFETCH_PAUSE).await,
        None => {}
    }
    match answer {
        Some(items) => {
            cache.keep(key, &items).await;
            Some(items)
        }
        None => kept.map(|(items, _)| items),
    }
}

pub fn enabled() -> bool {
    std::env::var("MINIPLY_MUSIC_CATALOG").map_or(true, |v| v != "0")
}

fn limit_bytes() -> u64 {
    std::env::var("MINIPLY_MUSIC_CATALOG_BYTES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_LIMIT_BYTES)
}

async fn json(state: &AppState, url: &str) -> Option<Value> {
    let response = state.http.get(url).send().await.ok()?;
    serde_json::from_slice(&response.error_for_status().ok()?.bytes().await.ok()?).ok()
}

/// Candidates by name with their fan count on Deezer (0 while unknown).
type Candidates = HashMap<String, (String, u64)>;

fn add(candidates: &mut Candidates, name: &str, fans: u64) {
    let key = title_key(name);
    if key.is_empty() {
        return;
    }
    let entry = candidates
        .entry(key)
        .or_insert_with(|| (name.to_owned(), 0));
    entry.1 = entry.1.max(fans);
}

fn deezer_artists(body: &Value) -> Vec<(u64, String, u64)> {
    body.get("data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|a| {
                    Some((
                        a.get("id")?.as_u64()?,
                        a.get("name")?.as_str()?.to_owned(),
                        a.get("nb_fan").and_then(Value::as_u64).unwrap_or(0),
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The ranking: who has the most fans among the artists in the charts and
/// those similar to them.
async fn build_ranking(state: &AppState, wanted: usize) -> Vec<(String, u64)> {
    let mut candidates = Candidates::new();
    let mut deezer_ids: HashMap<String, u64> = HashMap::new();
    // Deezer charts per genre.
    if let Some(genres) = json(state, "https://api.deezer.com/genre").await {
        for (id, _, _) in deezer_artists(&genres) {
            if SKIPPED_GENRES.contains(&id) {
                continue;
            }
            tokio::time::sleep(DEEZER_PAUSE).await;
            let url = format!("https://api.deezer.com/chart/{id}/artists?limit=100");
            if let Some(body) = json(state, &url).await {
                for (artist, name, fans) in deezer_artists(&body) {
                    deezer_ids.insert(title_key(&name), artist);
                    add(&mut candidates, &name, fans);
                }
            }
        }
    }
    // ListenBrainz: what people listen to most.
    for range in LISTENBRAINZ_RANGES {
        let url = format!(
            "https://api.listenbrainz.org/1/stats/sitewide/artists?count=1000&range={range}"
        );
        if let Some(body) = json(state, &url).await
            && let Some(list) = body.pointer("/payload/artists").and_then(Value::as_array)
        {
            for name in list.iter().filter_map(|a| a.get("artist_name")?.as_str()) {
                add(&mut candidates, name, 0);
            }
        }
    }
    // Apple Music charts.
    for country in CHART_COUNTRIES {
        for kind in ["songs", "albums"] {
            let url = format!(
                "https://rss.marketingtools.apple.com/api/v2/{country}/music/most-played/100/{kind}.json"
            );
            if let Some(body) = json(state, &url).await
                && let Some(list) = body.pointer("/feed/results").and_then(Value::as_array)
            {
                for name in list.iter().filter_map(|a| a.get("artistName")?.as_str()) {
                    // "A & B" counts for both.
                    for part in name.split([',', '&']) {
                        add(&mut candidates, part.trim(), 0);
                    }
                }
            }
        }
    }
    tracing::info!(
        names = candidates.len(),
        "music catalog: names from the charts collected"
    );
    // Fan counts for the names from elsewhere.
    let unknown: Vec<String> = candidates
        .iter()
        .filter(|(_, (_, fans))| *fans == 0)
        .map(|(_, (name, _))| name.clone())
        .collect();
    for name in unknown {
        tokio::time::sleep(DEEZER_PAUSE).await;
        let Ok(url) = Url::parse_with_params(
            "https://api.deezer.com/search/artist",
            &[("q", name.as_str()), ("limit", "1")],
        ) else {
            continue;
        };
        if let Some(body) = json(state, url.as_str()).await
            && let Some((id, found, fans)) = deezer_artists(&body).into_iter().next()
            && title_key(&found) == title_key(&name)
        {
            deezer_ids.insert(title_key(&found), id);
            add(&mut candidates, &found, fans);
        }
    }
    tracing::info!(
        names = candidates.len(),
        "music catalog: fan counts looked up"
    );
    // Similar artists of the most popular ones, until there are enough.
    let mut expanded = std::collections::HashSet::new();
    while candidates.len() < wanted * CANDIDATE_FACTOR {
        let next = candidates
            .iter()
            .filter(|(key, _)| !expanded.contains(*key) && deezer_ids.contains_key(*key))
            .max_by_key(|(_, (_, fans))| *fans)
            .map(|(key, _)| key.clone());
        let Some(key) = next else { break };
        expanded.insert(key.clone());
        tokio::time::sleep(DEEZER_PAUSE).await;
        let url = format!(
            "https://api.deezer.com/artist/{}/related?limit=50",
            deezer_ids[&key]
        );
        if let Some(body) = json(state, &url).await {
            for (id, name, fans) in deezer_artists(&body) {
                deezer_ids.insert(title_key(&name), id);
                add(&mut candidates, &name, fans);
            }
        }
    }
    rank(candidates, wanted)
}

fn rank(candidates: Candidates, wanted: usize) -> Vec<(String, u64)> {
    let mut ranked: Vec<(String, u64)> = candidates
        .into_values()
        .filter(|(_, fans)| *fans > 0)
        .collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    ranked.truncate(wanted);
    ranked
}

/// Songs and albums of one artist into the copy, the way the search asks for them.
async fn fetch_artist(state: &AppState, name: &str) -> Option<(u64, String)> {
    let found = crate::music::exact_artist(state, name).await;
    if let Some((id, _)) = &found {
        for entity in ["song", "album"] {
            if let Some(url) = crate::music::lookup_url(*id, entity) {
                catalog(state, url).await;
            }
        }
    }
    found
}

/// The track list of every album of an artist, as a tap on the album needs it.
async fn fetch_tracks(state: &AppState, apple_id: u64, name: &str) {
    let Some(url) = crate::music::lookup_url(apple_id, "album") else {
        return;
    };
    let Some(albums) = catalog(state, url).await else {
        return;
    };
    let ids: Vec<u64> = crate::music::chosen_items(&albums, "album", Some(name))
        .into_iter()
        .filter_map(|item| item.get("collectionId").and_then(Value::as_u64))
        .collect();
    for id in ids {
        let _ = crate::music::album_preview(state, id).await;
    }
}

pub fn spawn(state: AppState) {
    let Some(cache) = state.music_cache.clone() else {
        return;
    };
    if !state.music_jobs.is_dir() {
        return;
    }
    let (queue, mut wanted) = mpsc::channel::<u64>(PREFETCH_QUEUE);
    if PREFETCH.set(queue).is_ok() {
        let state = state.clone();
        tokio::spawn(ASKER.scope(Asker::Ahead, async move {
            while let Some(id) = wanted.recv().await {
                let _ = crate::music::album_preview(&state, id).await;
            }
        }));
    }
    tokio::spawn(ASKER.scope(Asker::Background, async move {
        // Let the server settle after a start.
        tokio::time::sleep(Duration::from_secs(120)).await;
        loop {
            let built = cache.meta("ranking_built").await.unwrap_or(0);
            if now().saturating_sub(built) > LIST_DAYS * 86_400 {
                tracing::info!("music catalog: ranking the most popular artists");
                let ranked = build_ranking(&state, DEFAULT_ARTISTS).await;
                if ranked.len() >= DEFAULT_ARTISTS / 10 {
                    tracing::info!(artists = ranked.len(), "music catalog: ranking ready");
                    cache.save_ranking(ranked).await;
                    cache.set_meta("ranking_built", now()).await;
                } else {
                    tracing::warn!(
                        artists = ranked.len(),
                        "music catalog: ranking incomplete, trying again later"
                    );
                    tokio::time::sleep(Duration::from_secs(3600)).await;
                    continue;
                }
            }
            if cache.bytes().await >= limit_bytes() {
                tokio::time::sleep(Duration::from_secs(6 * 3600)).await;
                continue;
            }
            if let Some(name) = cache.next_artist().await {
                let apple = fetch_artist(&state, &name).await;
                cache.mark_fetched(name, apple).await;
            } else if let Some((name, apple_id)) = cache.next_tracks().await {
                fetch_tracks(&state, apple_id, &name).await;
                cache.mark_tracks(apple_id).await;
            } else {
                tokio::time::sleep(Duration::from_secs(3600)).await;
            }
        }
    }));
}

/// For the status page.
pub async fn status(state: &AppState) -> Option<Value> {
    let cache = state.music_cache.as_ref()?;
    let (done, listed) = cache.progress().await;
    Some(serde_json::json!({
        "artists_ready": done,
        "artists_listed": listed,
        "bytes": cache.bytes().await,
        "limit_bytes": limit_bytes(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_used_fields_are_kept() {
        let item = serde_json::json!({
            "trackId": 1, "trackName": "A", "previewUrl": "https://x", "collectionPrice": 9.99,
            "artworkUrl100": "https://is1-ssl.mzstatic.com/a.jpg", "artworkUrl60": "https://x"
        });
        let kept = trimmed(&item);
        assert_eq!(kept.as_object().unwrap().len(), 3);
        assert!(kept.get("previewUrl").is_none());
    }

    #[test]
    fn ranking_by_fans_without_unknown_ones() {
        let mut candidates = Candidates::new();
        add(&mut candidates, "Drake", 30_000_000);
        add(&mut candidates, "drake", 10);
        add(&mut candidates, "Yeat", 232_223);
        add(&mut candidates, "Unbekannt", 0);
        add(&mut candidates, "Radiohead", 5_000_000);
        let ranked = rank(candidates, 2);
        assert_eq!(
            ranked,
            vec![
                ("Drake".into(), 30_000_000),
                ("Radiohead".into(), 5_000_000)
            ]
        );
    }

    #[tokio::test]
    async fn the_copy_answers_and_names_artists() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::open(&dir.path().join("c.sqlite")).unwrap();
        let url = "https://itunes.apple.com/lookup?id=1&entity=song".to_owned();
        cache
            .keep(
                url.clone(),
                &[serde_json::json!({"trackId": 5, "previewUrl": "x"})],
            )
            .await;
        let (items, age) = cache.response(url).await.unwrap();
        assert_eq!(items, vec![serde_json::json!({"trackId": 5})]);
        assert!(age < 5);
        assert!(cache.bytes().await > 0);

        cache
            .save_ranking(vec![("Drake".into(), 10), ("Yeat".into(), 5)])
            .await;
        assert_eq!(cache.next_artist().await.as_deref(), Some("Drake"));
        cache
            .mark_fetched("Drake".into(), Some((271256, "Drake".into())))
            .await;
        assert_eq!(cache.next_artist().await.as_deref(), Some("Yeat"));
        assert_eq!(
            cache.artist("  DRAKE ").await,
            Some((271256, "Drake".into()))
        );
        assert_eq!(cache.progress().await, (1, 2));
        // A new ranking keeps known catalog numbers.
        cache
            .save_ranking(vec![("Yeat".into(), 6), ("Drake".into(), 5)])
            .await;
        assert_eq!(cache.artist("drake").await, Some((271256, "Drake".into())));
        assert_eq!(cache.next_artist().await.as_deref(), Some("Yeat"));
    }

    #[tokio::test]
    async fn track_lists_come_after_the_artist_lists() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::open(&dir.path().join("c.sqlite")).unwrap();
        cache
            .save_ranking(vec![("Drake".into(), 10), ("Yeat".into(), 5)])
            .await;
        // Only artists with songs have albums to go through.
        assert_eq!(cache.next_tracks().await, None);
        cache
            .mark_fetched("Yeat".into(), Some((2, "Yeat".into())))
            .await;
        cache
            .mark_fetched("Drake".into(), Some((1, "Drake".into())))
            .await;
        assert_eq!(cache.next_tracks().await, Some(("Drake".into(), 1)));
        cache.mark_tracks(1).await;
        assert_eq!(cache.next_tracks().await, Some(("Yeat".into(), 2)));
        cache.mark_tracks(2).await;
        assert_eq!(cache.next_tracks().await, None);
    }

    #[test]
    fn an_older_copy_gets_the_track_list_column() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.sqlite");
        Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE artists (key TEXT PRIMARY KEY, name TEXT NOT NULL, fans INTEGER NOT NULL,
                 rank INTEGER, apple_id INTEGER, apple_name TEXT, fetched INTEGER);",
            )
            .unwrap();
        Cache::open(&path).unwrap();
        // Opening again must not try to add it twice.
        Cache::open(&path).unwrap();
    }

    #[tokio::test]
    async fn the_background_waits_while_the_app_asks() {
        LAST_USER_REQUEST.store(now(), Ordering::Relaxed);
        let waited = tokio::time::timeout(Duration::from_millis(200), wait_for_quiet()).await;
        assert!(waited.is_err());
        LAST_USER_REQUEST.store(0, Ordering::Relaxed);
        assert!(
            tokio::time::timeout(Duration::from_millis(200), wait_for_quiet())
                .await
                .is_ok()
        );
    }
}
