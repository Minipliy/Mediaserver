use crate::{ApiError, AppState, catalog::now};
use axum::{
    Json,
    body::Body,
    extract::{Path, Query, State},
    http::{HeaderMap, Method, StatusCode, header},
    response::{IntoResponse, Response},
};
use hmac::{Hmac, Mac};
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

const TICKET_LIFETIME: u64 = 6 * 60 * 60;

#[derive(Serialize, Deserialize)]
pub struct Ticket {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hls_path: Option<String>,
    pub expires_at: u64,
}

#[derive(Deserialize)]
pub struct TicketQuery {
    expires: u64,
    signature: String,
}

#[derive(Default, Deserialize)]
pub struct DownloadQuery {
    #[serde(default)]
    playback: bool,
}

fn mac(state: &AppState, id: &str, expires: u64) -> Hmac<Sha256> {
    let mut mac = Hmac::<Sha256>::new_from_slice(&state.token_hash).expect("HMAC key");
    mac.update(format!("miniply-stream-v1\n{id}\n{expires}").as_bytes());
    mac
}

pub async fn ticket(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Ticket>, ApiError> {
    let media = state.media(&id).await?;
    let expires = now() + TICKET_LIFETIME;
    let signature = hex::encode(mac(&state, &id, expires).finalize().into_bytes());
    Ok(Json(Ticket {
        path: format!("/stream/{id}?expires={expires}&signature={signature}"),
        // Player requests carry no header, and relative segment names keep
        // this path, so the signature is part of it.
        hls_path: media
            .hls
            .then(|| format!("/stream/{id}/hls/{expires}/{signature}/master.m3u8")),
        expires_at: expires,
    }))
}

fn check_ticket(state: &AppState, id: &str, expires: u64, signature: &str) -> Result<(), ApiError> {
    let current = now();
    let signature = hex::decode(signature).map_err(|_| ApiError::unauthorized())?;
    if expires <= current
        || expires > current + TICKET_LIFETIME
        || mac(state, id, expires).verify_slice(&signature).is_err()
    {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

pub async fn signed_hls(
    State(state): State<AppState>,
    Path((id, expires, signature, file)): Path<(String, u64, String, String)>,
) -> Result<Response, ApiError> {
    check_ticket(&state, &id, expires, &signature)?;
    let content_type = crate::hls::content_type(&file).ok_or_else(ApiError::not_found)?;
    let media = state.media(&id).await?;
    if !media.hls {
        return Err(ApiError::not_found());
    }
    let root = state.root.clone();
    let path = format!("{}/{file}", crate::hls::directory(&id));
    let opened =
        tokio::task::spawn_blocking(move || crate::file_access::open_regular_nofollow(&root, path))
            .await
            .map_err(|_| ApiError::internal())?
            .map_err(|_| ApiError::not_found())?;
    let size = opened.metadata().map_err(|_| ApiError::not_found())?.len();
    Ok((
        [
            (header::CONTENT_TYPE, content_type.to_owned()),
            (header::CONTENT_LENGTH, size.to_string()),
            (header::CACHE_CONTROL, "private, max-age=3600".to_owned()),
        ],
        Body::from_stream(ReaderStream::with_capacity(
            tokio::fs::File::from_std(opened),
            64 * 1024,
        )),
    )
        .into_response())
}

pub async fn signed_stream(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<TicketQuery>,
    method: Method,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_ticket(&state, &id, query.expires, &query.signature)?;
    serve(state, id, method, headers, false, true).await
}

pub async fn download(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<DownloadQuery>,
    method: Method,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    serve(state, id, method, headers, true, query.playback).await
}

/// Inclusive byte bounds. Empty files have no satisfiable byte range.
fn byte_range(value: &str, size: u64) -> Result<(u64, u64), ()> {
    let value = value.strip_prefix("bytes=").ok_or(())?;
    if size == 0 || value.contains(',') {
        return Err(());
    }
    let (start, end) = value.split_once('-').ok_or(())?;
    if start.is_empty() {
        let suffix = end.parse::<u64>().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        return Ok((size.saturating_sub(suffix), size - 1));
    }
    let start = start.parse::<u64>().map_err(|_| ())?;
    let end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>().map_err(|_| ())?.min(size - 1)
    };
    if start >= size || end < start {
        Err(())
    } else {
        Ok((start, end))
    }
}

async fn serve(
    state: AppState,
    id: String,
    method: Method,
    headers: HeaderMap,
    attachment: bool,
    prefer_playback: bool,
) -> Result<Response, ApiError> {
    let media = state.media(&id).await?;
    let root = state.root.clone();
    let source = media.clone();
    // Open using a capability, not a canonicalize-then-reopen check: a symlink
    // swapped after indexing must never escape the media directory.
    let (file, served_path, served_name) = tokio::task::spawn_blocking(move || {
        let file = crate::file_access::open_regular(&root, &source.path)?;
        if prefer_playback {
            let metadata = file.metadata()?;
            let modified_nanos = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            if let Some(prepared) =
                crate::playback::open(&root, &source, metadata.len(), modified_nanos)
            {
                let stem = std::path::Path::new(&source.name)
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy();
                let name = format!("{stem}.{}", prepared.variant.file_extension);
                return Ok((prepared.file, prepared.path, name));
            }
        }
        Ok::<_, std::io::Error>((file, source.path, source.name))
    })
    .await
    .map_err(|_| ApiError::internal())?
    .map_err(|_| ApiError::not_found())?;
    let meta = file.metadata().map_err(|_| ApiError::not_found())?;
    if !meta.is_file() {
        return Err(ApiError::not_found());
    }
    let size = meta.len();
    let mut start = 0;
    let mut length = size;
    let mut status = StatusCode::OK;
    let mut result_headers = HeaderMap::new();
    result_headers.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
    // URLSession can only resume a download against a validator.
    let modified_nanos = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let etag = format!("\"{size:x}-{modified_nanos:x}\"");
    result_headers.insert(header::ETAG, etag.parse().unwrap());
    // If-Range with another validator falls back to the entire file.
    let range_valid = headers
        .get(header::IF_RANGE)
        .is_none_or(|value| value.as_bytes() == etag.as_bytes());
    if method == Method::GET
        && range_valid
        && let Some(range) = headers.get(header::RANGE)
    {
        match range.to_str().ok().and_then(|v| byte_range(v, size).ok()) {
            Some((first, last)) => {
                start = first;
                length = last - first + 1;
                status = StatusCode::PARTIAL_CONTENT;
                result_headers.insert(
                    header::CONTENT_RANGE,
                    format!("bytes {first}-{last}/{size}").parse().unwrap(),
                );
            }
            None => {
                result_headers.insert(
                    header::CONTENT_RANGE,
                    format!("bytes */{size}").parse().unwrap(),
                );
                return Ok((
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    result_headers,
                    Body::empty(),
                )
                    .into_response());
            }
        }
    }
    let mime = match crate::formats::from_path(&served_path) {
        Some(format) => format.content_type.to_owned(),
        None => mime_guess::from_path(&served_path)
            .first_or_octet_stream()
            .to_string(),
    };
    result_headers.insert(header::CONTENT_TYPE, mime.parse().unwrap());
    result_headers.insert(header::CONTENT_LENGTH, length.to_string().parse().unwrap());
    if attachment || media.kind == "file" {
        let name = utf8_percent_encode(&served_name, NON_ALPHANUMERIC);
        result_headers.insert(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"download\"; filename*=UTF-8''{name}")
                .parse()
                .map_err(|_| ApiError::internal())?,
        );
    }
    let body = if method == Method::HEAD {
        Body::empty()
    } else {
        let mut file = tokio::fs::File::from_std(file);
        file.seek(std::io::SeekFrom::Start(start))
            .await
            .map_err(|_| ApiError::internal())?;
        Body::from_stream(ReaderStream::with_capacity(file.take(length), 64 * 1024))
    };
    Ok((status, result_headers, body).into_response())
}

#[cfg(test)]
mod tests {
    use super::byte_range;
    #[test]
    fn ranges() {
        for (input, expected) in [
            ("bytes=0-0", (0, 0)),
            ("bytes=3-", (3, 9)),
            ("bytes=-3", (7, 9)),
            ("bytes=-30", (0, 9)),
            ("bytes=8-99", (8, 9)),
        ] {
            assert_eq!(byte_range(input, 10), Ok(expected));
        }
        for input in [
            "bytes=10-",
            "bytes=9-2",
            "bytes=-0",
            "bytes=a-2",
            "bytes=1-2,4-5",
            "items=0-2",
            "bytes=18446744073709551616-",
        ] {
            assert!(byte_range(input, 10).is_err(), "{input}");
        }
        assert!(byte_range("bytes=0-", 0).is_err());
    }
}
