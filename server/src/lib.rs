pub mod analysis;
pub mod catalog;
pub mod extras;
mod file_access;
pub mod follows;
mod formats;
mod genius;
mod hls;
pub mod metadata;
pub mod music;
pub mod music_catalog;
mod ops;
mod organize;
mod personal;
mod playback;
mod store;
mod stream;
mod text;
pub mod thumbnails;
mod trash;
pub mod web;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, Request, State},
    http::{StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use cap_std::fs::Dir;
use catalog::{Catalog, Media};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, atomic::AtomicUsize},
};
use store::{Playlist, Progress, Store};
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, RwLock};

#[derive(Clone)]
pub struct AppState {
    root: Arc<Dir>,
    root_path: PathBuf,
    token_hash: [u8; 32],
    catalog: Arc<RwLock<Catalog>>,
    scan_lock: Arc<Mutex<()>>,
    store: Store,
    metadata: Arc<RwLock<HashMap<String, metadata::Entry>>>,
    metadata_pending: Arc<AtomicUsize>,
    http: reqwest::Client,
    thumbnails: Arc<RwLock<std::collections::HashSet<String>>>,
    music_jobs: PathBuf,
    deletes: bool,
    analysis: Arc<RwLock<analysis::Analysis>>,
    first_seen: Arc<RwLock<HashMap<String, u64>>>,
    music_cache: Option<music_catalog::Cache>,
}

impl AppState {
    pub async fn new(
        root_path: PathBuf,
        token: &str,
        database: PathBuf,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        if token.len() < 32
            || token.chars().any(char::is_whitespace)
            || token.starts_with("REPLACE_WITH_")
        {
            return Err("MINIPLY_TOKEN must contain at least 32 non-whitespace characters".into());
        }
        let root_path = root_path.canonicalize()?;
        if database.exists() && database.canonicalize()?.starts_with(&root_path) {
            return Err("database must be outside the media root".into());
        }
        let parent = database
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(std::path::Path::new("."));
        if parent.canonicalize()?.starts_with(&root_path) {
            return Err("database must be outside the media root".into());
        }
        let music_jobs = parent.canonicalize()?.join("music-jobs");
        let root = Arc::new(Dir::open_ambient_dir(
            &root_path,
            cap_std::ambient_authority(),
        )?);
        let store = Store::open(&database)?;
        let known = store.load_metadata().await?;
        let thumbnails = store.thumbnail_ids().await?;
        let analysis = store.load_analysis().await?;
        let first_seen = store.first_seen().await?;
        // A local copy of the music catalog, in its own database next to the main one.
        let music_cache = music_catalog::enabled()
            .then(|| music_catalog::Cache::open(&database.with_file_name("music-catalog.sqlite")))
            .transpose()?;
        let this = Self {
            root,
            root_path,
            token_hash: Sha256::digest(token).into(),
            catalog: Arc::new(RwLock::new(Catalog::default())),
            scan_lock: Arc::new(Mutex::new(())),
            store,
            metadata: Arc::new(RwLock::new(known)),
            metadata_pending: Arc::new(AtomicUsize::new(0)),
            http: reqwest::Client::builder()
                .user_agent(
                    "Mediaserver/1.0 (+https://mediaserver.minipliy.net; private media server)",
                )
                .timeout(std::time::Duration::from_secs(15))
                .https_only(true)
                .build()?,
            thumbnails: Arc::new(RwLock::new(thumbnails)),
            music_jobs,
            deletes: trash::enabled_by_environment(),
            analysis: Arc::new(RwLock::new(analysis)),
            first_seen: Arc::new(RwLock::new(first_seen)),
            music_cache,
        };
        this.rescan().await?;
        Ok(this)
    }

    /// Allow deleting from the app, whatever `MINIPLY_DELETES` says.
    pub fn with_deletes(mut self) -> Self {
        self.deletes = true;
        self
    }

    pub fn spawn_trash_cleanup(&self) {
        trash::spawn(self.clone());
    }

    pub async fn rescan(&self) -> Result<(), ApiError> {
        let _lock = self.scan_lock.lock().await;
        let root = self.root.clone();
        // Move the old index to the scan worker? Keep reads available instead:
        // clone once per scan, then swap atomically after traversal completes.
        let previous = {
            let current = self.catalog.read().await;
            Catalog {
                files: current.files.clone(),
                ..Catalog::default()
            }
        };
        let next = tokio::task::spawn_blocking(move || catalog::scan(&root, &previous))
            .await
            .map_err(|_| ApiError::internal())?;
        if next.scan_errors > 0 {
            tracing::warn!(
                count = next.scan_errors,
                entries = %next.skipped.join("; "),
                "library scan skipped unreadable entries or reached a limit"
            );
        }
        let mut next = next;
        self.analysis.read().await.apply(&mut next);
        self.note_first_seen(&mut next).await;
        let mut current = self.catalog.write().await;
        let unchanged = current.changed_at > 0
            && current.files.len() == next.files.len()
            && next.files.iter().all(|(id, media)| {
                current.files.get(id).is_some_and(|known| {
                    known.modified == media.modified
                        && known.modified_nanos == media.modified_nanos
                        && known.bytes == media.bytes
                })
            });
        next.changed_at = if unchanged {
            current.changed_at
        } else {
            next.scanned_at
        };
        *current = next;
        Ok(())
    }

    /// Dates for files not seen before: their modification time, or that of an older
    /// copy in the trash when the file replaced one (a song loaded again in better quality).
    async fn note_first_seen(&self, catalog: &mut Catalog) {
        let unknown: Vec<(String, String, u64)> = {
            let known = self.first_seen.read().await;
            catalog
                .files
                .values()
                .filter(|m| !known.contains_key(&m.id))
                .map(|m| (m.id.clone(), m.path.clone(), m.modified))
                .collect()
        };
        if !unknown.is_empty() {
            let root = self.root_path.clone();
            let older = tokio::task::spawn_blocking(move || trash::earliest_copies(&root))
                .await
                .unwrap_or_default();
            let rows: Vec<(String, u64)> = unknown
                .into_iter()
                .map(|(id, path, modified)| {
                    let at = older.get(&path).map_or(modified, |&old| old.min(modified));
                    (id, at)
                })
                .collect();
            if self.store.save_first_seen(rows.clone()).await.is_ok() {
                self.first_seen.write().await.extend(rows);
            }
        }
        let known = self.first_seen.read().await;
        for media in catalog.files.values_mut() {
            media.added = known.get(&media.id).copied();
        }
    }

    async fn media(&self, id: &str) -> Result<Media, ApiError> {
        self.catalog
            .read()
            .await
            .files
            .get(id)
            .cloned()
            .ok_or_else(ApiError::not_found)
    }
}

#[derive(Debug)]
pub struct ApiError(StatusCode, &'static str);
impl ApiError {
    pub fn internal() -> Self {
        Self(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
    }
    pub fn not_found() -> Self {
        Self(StatusCode::NOT_FOUND, "not found")
    }
    pub fn unauthorized() -> Self {
        Self(
            StatusCode::UNAUTHORIZED,
            "authentication required or playback ticket expired",
        )
    }
    pub(crate) fn bad_request(message: &'static str) -> Self {
        Self(StatusCode::BAD_REQUEST, message)
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut response = (self.0, Json(serde_json::json!({"error": self.1}))).into_response();
        if self.0 == StatusCode::UNAUTHORIZED {
            response
                .headers_mut()
                .insert(header::WWW_AUTHENTICATE, "Bearer".parse().unwrap());
        }
        response
    }
}

pub fn router(state: AppState) -> Router {
    let api = Router::new()
        .route("/v1/library", get(library))
        .route("/v1/files", get(files))
        .route("/v1/storage", get(storage))
        .route("/v1/status", get(ops::status))
        .route(
            "/v1/diagnostics",
            post(ops::diagnostics).layer(DefaultBodyLimit::max(ops::MAX_REPORT)),
        )
        .route(
            "/v1/push/devices",
            get(ops::devices).post(ops::register_device),
        )
        .route("/v1/scan", post(rescan))
        .route("/v1/media/{id}/ticket", post(stream::ticket))
        .route("/v1/files/{id}/download", get(stream::download))
        .route("/v1/progress/{id}", get(progress).put(save_progress))
        .route("/v1/metadata", get(metadata_snapshot))
        .route("/v1/artwork/{id}", get(artwork))
        .route("/v1/lyrics/{id}", get(extras::lyrics))
        .route("/v1/subtitles/{id}", get(extras::subtitles))
        .route(
            "/v1/upload",
            post(extras::upload).layer(DefaultBodyLimit::disable()),
        )
        .route(
            "/v1/uploads/{id}",
            get(extras::upload_status)
                .delete(extras::upload_cancel)
                .put(extras::upload_chunk)
                .layer(DefaultBodyLimit::disable()),
        )
        .route(
            "/v1/personal/sync",
            post(personal::sync).layer(DefaultBodyLimit::max(personal::MAX_BODY)),
        )
        .route(
            "/v1/media/delete",
            post(trash::delete).layer(DefaultBodyLimit::max(trash::MAX_BODY)),
        )
        .route("/v1/music/search", get(music::search))
        .route("/v1/music/artist", get(music::artist))
        .route("/v1/music/preview", get(music::preview))
        .route("/v1/music/jobs", get(music::jobs).post(music::create_job))
        .route(
            "/v1/music/follows",
            get(follows::list).post(follows::change),
        )
        .route(
            "/v1/music/jobs/{id}",
            axum::routing::delete(music::delete_job),
        )
        .route("/v1/playlists", get(playlists).post(create_playlist))
        .route(
            "/v1/playlists/{id}",
            axum::routing::put(update_playlist).delete(delete_playlist),
        )
        .route_layer(middleware::from_fn_with_state(state.clone(), authenticate))
        .layer(middleware::from_fn(unchanged_answers));
    Router::new()
        .merge(api)
        .route(
            "/healthz",
            get(|| async { Json(serde_json::json!({"status":"ok"})) }),
        )
        .merge(web::routes())
        .route("/stream/{id}", get(stream::signed_stream))
        .route(
            "/stream/{id}/hls/{expires}/{signature}/{*file}",
            get(stream::signed_hls),
        )
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn(security_headers))
        .with_state(state)
}

async fn authenticate(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Result<Response, ApiError> {
    let token = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    let candidate: [u8; 32] = Sha256::digest(token).into();
    if !bool::from(candidate.ct_eq(&state.token_hash)) {
        return Err(ApiError::unauthorized());
    }
    Ok(next.run(request).await)
}

/// Lists the apps fetch again and again (library, online infos, playlists,
/// followed artists) carry a fingerprint. A client that sends it back gets
/// "304 Not Modified" without a body when nothing changed: on mobile data a
/// check costs a few bytes instead of megabytes.
async fn unchanged_answers(request: Request, next: Next) -> Response {
    const PATHS: [&str; 4] = [
        "/v1/library",
        "/v1/metadata",
        "/v1/playlists",
        "/v1/music/follows",
    ];
    let watched =
        request.method() == axum::http::Method::GET && PATHS.contains(&request.uri().path());
    let sent = request
        .headers()
        .get(header::IF_NONE_MATCH)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let response = next.run(request).await;
    if !watched || response.status() != StatusCode::OK {
        return response;
    }
    let (mut parts, body) = response.into_parts();
    let Ok(bytes) = axum::body::to_bytes(body, 256 * 1024 * 1024).await else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let digest = Sha256::digest(&bytes);
    let tag = format!("\"{}\"", hex::encode(&digest[..16]));
    parts.headers.insert(header::ETAG, tag.parse().unwrap());
    // Kept on the device, but always asked about again.
    parts
        .headers
        .insert(header::CACHE_CONTROL, "private, no-cache".parse().unwrap());
    if sent
        .as_deref()
        .is_some_and(|sent| sent.split(',').any(|one| one.trim() == tag))
    {
        parts.status = StatusCode::NOT_MODIFIED;
        parts.headers.remove(header::CONTENT_LENGTH);
        return Response::from_parts(parts, axum::body::Body::empty());
    }
    Response::from_parts(parts, axum::body::Body::from(bytes))
}

async fn security_headers(request: Request, next: Next) -> Response {
    let mut result = next.run(request).await;
    let headers = result.headers_mut();
    if !headers.contains_key(header::CACHE_CONTROL) {
        headers.insert(header::CACHE_CONTROL, "private, no-store".parse().unwrap());
    }
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    headers.insert("referrer-policy", "no-referrer".parse().unwrap());
    result
}

#[derive(Deserialize)]
struct PageQuery {
    kind: Option<String>,
    search: Option<String>,
    offset: Option<usize>,
    limit: Option<usize>,
}
#[derive(Serialize)]
struct Page {
    items: Vec<Media>,
    total: usize,
    offset: usize,
    scanned_at: u64,
    scan_errors: usize,
}

async fn library(
    State(state): State<AppState>,
    Query(query): Query<PageQuery>,
) -> Result<Json<Page>, ApiError> {
    if query
        .kind
        .as_ref()
        .is_some_and(|k| !["audio", "video", "file"].contains(&k.as_str()))
    {
        return Err(ApiError::bad_request("unknown media kind"));
    }
    let catalog = state.catalog.read().await;
    let search = query.search.unwrap_or_default().to_lowercase();
    let mut items: Vec<_> = catalog
        .files
        .values()
        .filter(|m| query.kind.as_ref().is_none_or(|k| k == &m.kind))
        .filter(|m| {
            search.is_empty()
                || format!(
                    "{} {} {} {}",
                    m.title,
                    m.path,
                    m.artist.as_deref().unwrap_or(""),
                    m.album.as_deref().unwrap_or("")
                )
                .to_lowercase()
                .contains(&search)
        })
        .collect();
    items.sort_by(|a, b| a.path.cmp(&b.path));
    let total = items.len();
    let offset = query.offset.unwrap_or(0);
    let mut page: Vec<_> = items
        .into_iter()
        .skip(offset)
        .take(query.limit.unwrap_or(200).clamp(1, 500))
        .cloned()
        .collect();
    genius::apply_tracklists(
        catalog.files.values(),
        &*state.metadata.read().await,
        &mut page,
    );
    Ok(Json(Page {
        items: page,
        total,
        offset,
        scanned_at: catalog.changed_at,
        scan_errors: catalog.scan_errors,
    }))
}

#[derive(Deserialize)]
struct DirectoryQuery {
    #[serde(default)]
    path: String,
    offset: Option<usize>,
    limit: Option<usize>,
}
async fn files(
    State(state): State<AppState>,
    Query(query): Query<DirectoryQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let catalog = state.catalog.read().await;
    if !query.path.is_empty() && !catalog.directories.contains(&query.path) {
        return Err(ApiError::not_found());
    }
    let parent = |p: &str| {
        std::path::Path::new(p)
            .parent()
            .unwrap_or(std::path::Path::new(""))
            .to_string_lossy()
            .into_owned()
    };
    let directories: Vec<_> = catalog
        .directories
        .iter()
        .filter(|p| parent(p) == query.path)
        .collect();
    let mut files: Vec<_> = catalog
        .files
        .values()
        .filter(|m| parent(&m.path) == query.path)
        .collect();
    files.sort_by(|a, b| a.name.cmp(&b.name));
    let total = files.len();
    let files: Vec<_> = files
        .into_iter()
        .skip(query.offset.unwrap_or(0))
        .take(query.limit.unwrap_or(200).clamp(1, 500))
        .cloned()
        .collect();
    Ok(Json(
        serde_json::json!({"path":query.path,"directories":directories,"files":files,"total":total}),
    ))
}

async fn storage(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let deletes = state.deletes;
    let root = state.root_path;
    let (total, available) = tokio::task::spawn_blocking(move || {
        Ok::<_, std::io::Error>((fs2::total_space(&root)?, fs2::available_space(&root)?))
    })
    .await
    .map_err(|_| ApiError::internal())?
    .map_err(|_| ApiError::internal())?;
    let catalog = state.catalog.read().await;
    Ok(Json(
        serde_json::json!({"total_bytes":total,"available_bytes":available,"indexed_bytes":catalog.files.values().map(|m| m.bytes).sum::<u64>(),"file_count":catalog.files.len(),"scanned_at":catalog.scanned_at,"scan_errors":catalog.scan_errors,"uploads":extras::uploads_enabled(),"deletes":deletes}),
    ))
}
async fn rescan(State(state): State<AppState>) -> Result<StatusCode, ApiError> {
    state.rescan().await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn metadata_snapshot(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(metadata::snapshot(&state).await)
}

const MAX_ARTWORK_BYTES: u64 = 25 * 1024 * 1024;

/// Song covers are square. Video thumbnails kept as covers are 16:9, which the
/// lock screen would show as they are: keep their middle. Anything that cannot
/// be read stays as it is.
fn square_cover(mime: String, data: Vec<u8>) -> (String, Vec<u8>) {
    let reader = || {
        image::ImageReader::new(std::io::Cursor::new(&data))
            .with_guessed_format()
            .ok()
    };
    let Some((width, height)) = reader().and_then(|r| r.into_dimensions().ok()) else {
        return (mime, data);
    };
    if width == height {
        return (mime, data);
    }
    let Some(decoded) = reader().and_then(|r| r.decode().ok()) else {
        return (mime, data);
    };
    let picture = decoded.to_rgb8();
    // Video thumbnails often carry black bars in the image itself.
    let dark_row = |y: u32| (0..width).all(|x| picture.get_pixel(x, y).0.iter().all(|c| *c < 24));
    let top = (0..height).find(|y| !dark_row(*y)).unwrap_or(0);
    let bottom = (0..height)
        .rev()
        .find(|y| !dark_row(*y))
        .unwrap_or(height - 1);
    let content = bottom.saturating_sub(top) + 1;
    let side = width.min(content);
    let square = image::imageops::crop_imm(
        &picture,
        (width - side) / 2,
        top + (content - side) / 2,
        side,
        side,
    )
    .to_image();
    let mut encoded = std::io::Cursor::new(Vec::new());
    if square
        .write_to(&mut encoded, image::ImageFormat::Jpeg)
        .is_err()
    {
        return (mime, data);
    }
    ("image/jpeg".into(), encoded.into_inner())
}

/// Cover images: an image file from the library, embedded artwork of an
/// audio file, or an image downloaded by the online metadata worker.
async fn artwork(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let stored = match (id.strip_prefix("web-"), id.strip_prefix("thumb-")) {
        (Some(hash), _) => hash.len() == 32 && hash.bytes().all(|b| b.is_ascii_hexdigit()),
        (_, Some(media)) => media.len() == 64 && media.bytes().all(|b| b.is_ascii_hexdigit()),
        _ => false,
    };
    let (content_type, data) = if stored {
        state
            .store
            .artwork(id)
            .await?
            .ok_or_else(ApiError::not_found)?
    } else {
        let media = state.media(&id).await?;
        let root = state.root.clone();
        tokio::task::spawn_blocking(move || -> Option<(String, Vec<u8>)> {
            use std::io::Read;
            let file = file_access::open_regular(&root, &media.path).ok()?;
            if media.kind == "file" && organize::is_image(&media.path) {
                let mut data = Vec::new();
                file.take(MAX_ARTWORK_BYTES + 1)
                    .read_to_end(&mut data)
                    .ok()?;
                if data.len() as u64 > MAX_ARTWORK_BYTES {
                    return None;
                }
                let mime = mime_guess::from_path(&media.path)
                    .first_or_octet_stream()
                    .to_string();
                return Some((mime, data));
            }
            if media.kind != "audio" || !media.embedded_art {
                return None;
            }
            use lofty::prelude::*;
            let tagged = lofty::probe::Probe::new(file)
                .guess_file_type()
                .ok()?
                .options(lofty::config::ParseOptions::new().read_cover_art(true))
                .read()
                .ok()?;
            let pictures: Vec<_> = tagged.tags().iter().flat_map(|t| t.pictures()).collect();
            let picture = pictures
                .iter()
                .find(|p| p.pic_type() == lofty::picture::PictureType::CoverFront)
                .or_else(|| pictures.first())?;
            let mime = picture
                .mime_type()
                .map(|m| m.as_str().to_owned())
                .filter(|m| m.starts_with("image/"))
                .unwrap_or_else(|| "image/jpeg".into());
            Some(square_cover(mime, picture.data().to_vec()))
        })
        .await
        .map_err(|_| ApiError::internal())?
        .ok_or_else(ApiError::not_found)?
    };
    let content_type = content_type
        .parse()
        .unwrap_or_else(|_| header::HeaderValue::from_static("application/octet-stream"));
    Ok((
        [
            (header::CONTENT_TYPE, content_type),
            (
                header::CACHE_CONTROL,
                header::HeaderValue::from_static("private, max-age=604800"),
            ),
        ],
        data,
    )
        .into_response())
}

async fn progress(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Progress>, ApiError> {
    state.media(&id).await?;
    Ok(Json(state.store.progress(id).await?))
}
async fn save_progress(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(progress): Json<Progress>,
) -> Result<StatusCode, ApiError> {
    state.media(&id).await?;
    if !progress.seconds.is_finite() || !(0.0..=604_800.0).contains(&progress.seconds) {
        return Err(ApiError::bad_request("seconds out of bounds"));
    }
    // When the position was saved on the device, maybe long ago without a
    // connection; never in the future, and 0 (older apps) means now.
    let now = catalog::now();
    let at = if progress.updated_at == 0 {
        now
    } else {
        progress.updated_at.min(now)
    };
    state.store.save_progress(id, progress.seconds, at).await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn playlists(State(state): State<AppState>) -> Result<Json<Vec<Playlist>>, ApiError> {
    Ok(Json(state.store.playlists().await?))
}
#[derive(Deserialize)]
struct PlaylistInput {
    name: String,
    #[serde(default)]
    media_ids: Vec<String>,
}
async fn validate_playlist(
    state: &AppState,
    input: PlaylistInput,
    id: String,
) -> Result<Playlist, ApiError> {
    let name = input.name.trim().to_owned();
    if name.is_empty() || name.len() > 200 || input.media_ids.len() > 500 {
        return Err(ApiError::bad_request(
            "playlist requires a name of 1..200 bytes and at most 500 tracks",
        ));
    }
    for id in &input.media_ids {
        if state.media(id).await?.kind != "audio" {
            return Err(ApiError::bad_request("playlists contain audio files only"));
        }
    }
    Ok(Playlist {
        id,
        name,
        media_ids: input.media_ids,
    })
}
async fn create_playlist(
    State(state): State<AppState>,
    Json(input): Json<PlaylistInput>,
) -> Result<(StatusCode, Json<Playlist>), ApiError> {
    let playlist = validate_playlist(&state, input, uuid::Uuid::new_v4().to_string()).await?;
    Ok((
        StatusCode::CREATED,
        Json(state.store.save_playlist(playlist, true).await?),
    ))
}
async fn update_playlist(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(input): Json<PlaylistInput>,
) -> Result<Json<Playlist>, ApiError> {
    let playlist = validate_playlist(&state, input, id).await?;
    Ok(Json(state.store.save_playlist(playlist, false).await?))
}
async fn delete_playlist(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    state.store.delete_playlist(id).await?;
    Ok(StatusCode::NO_CONTENT)
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.1)
    }
}
impl std::error::Error for ApiError {}

#[cfg(test)]
mod cover_tests {
    use super::square_cover;

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut data = std::io::Cursor::new(Vec::new());
        image::RgbImage::new(width, height)
            .write_to(&mut data, image::ImageFormat::Png)
            .unwrap();
        data.into_inner()
    }

    #[test]
    fn wide_covers_become_square() {
        let (mime, data) = square_cover("image/png".into(), png(160, 90));
        assert_eq!(mime, "image/jpeg");
        let cover = image::load_from_memory(&data).unwrap();
        assert_eq!((cover.width(), cover.height()), (90, 90));
    }

    #[test]
    fn black_bars_are_removed() {
        let mut picture = image::RgbImage::new(160, 120);
        for y in 30..90 {
            for x in 0..160 {
                picture.put_pixel(x, y, image::Rgb([200, 100, 50]));
            }
        }
        let mut data = std::io::Cursor::new(Vec::new());
        picture
            .write_to(&mut data, image::ImageFormat::Png)
            .unwrap();
        let (_, data) = square_cover("image/png".into(), data.into_inner());
        let cover = image::load_from_memory(&data).unwrap().to_rgb8();
        assert_eq!(cover.dimensions(), (60, 60));
        assert!(cover.get_pixel(30, 2).0[0] > 150);
    }

    #[test]
    fn square_and_unreadable_covers_stay() {
        let square = png(50, 50);
        assert_eq!(
            square_cover("image/png".into(), square.clone()),
            ("image/png".to_owned(), square)
        );
        assert_eq!(
            square_cover("image/png".into(), vec![1, 2, 3]),
            ("image/png".to_owned(), vec![1, 2, 3])
        );
    }
}
