use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use hmac::{Hmac, Mac};
use miniply_server::{AppState, router};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tower::ServiceExt;

const TOKEN: &str = "test-only-0123456789-abcdefghijklmnopqrstuvwxyz";

struct Fixture {
    _temp: TempDir,
    state: AppState,
    app: Router,
    root: std::path::PathBuf,
    database: std::path::PathBuf,
}
impl Fixture {
    async fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("media");
        let database = temp.path().join("state.sqlite");
        std::fs::create_dir_all(root.join("Album")).unwrap();
        std::fs::create_dir(root.join("Empty")).unwrap();
        std::fs::write(root.join("Album/song.mp3"), b"0123456789").unwrap();
        std::fs::write(root.join("clip.mp4"), b"abcdefghij").unwrap();
        std::fs::write(root.join("empty.txt"), []).unwrap();
        std::fs::write(root.join(".secret"), b"hidden").unwrap();
        let state = AppState::new(root.clone(), TOKEN, database.clone())
            .await
            .unwrap();
        Self {
            app: router(state.clone()),
            state,
            root,
            database,
            _temp: temp,
        }
    }
    async fn call(
        &self,
        method: &str,
        uri: &str,
        authenticated: bool,
        body: Option<Value>,
        headers: &[(&str, &str)],
    ) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
        call(&self.app, method, uri, authenticated, body, headers).await
    }
    async fn id(&self, kind: &str) -> String {
        let (_, _, body) = self
            .call("GET", &format!("/v1/library?kind={kind}"), true, None, &[])
            .await;
        let page: Value = serde_json::from_slice(&body).unwrap();
        page["items"][0]["id"].as_str().unwrap().to_owned()
    }
    async fn ticket(&self, id: &str) -> String {
        let (status, _, body) = self
            .call("POST", &format!("/v1/media/{id}/ticket"), true, None, &[])
            .await;
        assert_eq!(status, StatusCode::OK);
        serde_json::from_slice::<Value>(&body).unwrap()["path"]
            .as_str()
            .unwrap()
            .to_owned()
    }
    async fn media(&self, path: &str) -> Value {
        let (_, _, body) = self
            .call("GET", "/v1/library?limit=500", true, None, &[])
            .await;
        let page: Value = serde_json::from_slice(&body).unwrap();
        page["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["path"] == path)
            .unwrap_or_else(|| panic!("{path} was not indexed"))
            .clone()
    }
    fn prepare(&self, path: &str, filename: &str, data: &[u8]) -> (std::path::PathBuf, Value) {
        let id = hex::encode(Sha256::digest(path.as_bytes()));
        let directory = self.root.join(".miniply-playback").join(id);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join(filename), data).unwrap();
        let metadata = std::fs::metadata(self.root.join(path)).unwrap();
        let modified_ns = metadata
            .modified()
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let manifest = json!({
            "version": 1,
            "source_path": path,
            "source_bytes": metadata.len(),
            "source_modified_ns": modified_ns,
            "filename": filename,
            "bytes": data.len(),
        });
        std::fs::write(directory.join("manifest.json"), manifest.to_string()).unwrap();
        (directory, manifest)
    }
}
async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    authenticated: bool,
    body: Option<Value>,
    headers: &[(&str, &str)],
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut builder = Request::builder().method(method).uri(uri);
    if authenticated {
        builder = builder.header("Authorization", format!("Bearer {TOKEN}"));
    }
    if body.is_some() {
        builder = builder.header("Content-Type", "application/json");
    }
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let response = app
        .clone()
        .oneshot(
            builder
                .body(Body::from(body.map(|b| b.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let (parts, body) = response.into_parts();
    (
        parts.status,
        parts.headers,
        to_bytes(body, 1024 * 1024).await.unwrap().to_vec(),
    )
}

#[tokio::test]
async fn all_private_routes_require_bearer() {
    let f = Fixture::new().await;
    for (method, path) in [
        ("GET", "/v1/library"),
        ("GET", "/v1/files"),
        ("GET", "/v1/storage"),
        ("GET", "/v1/playlists"),
        ("POST", "/v1/scan"),
        ("POST", "/v1/media/id/ticket"),
        ("GET", "/v1/files/id/download"),
        ("PUT", "/v1/progress/id"),
        ("DELETE", "/v1/playlists/id"),
    ] {
        let (status, headers, _) = f.call(method, path, false, None, &[]).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{path}");
        assert_eq!(headers["cache-control"], "private, no-store");
    }
    assert_eq!(
        f.call(
            "GET",
            &format!("/v1/library?token={TOKEN}"),
            false,
            None,
            &[]
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.call(
            "GET",
            "/v1/library",
            false,
            None,
            &[("Authorization", "Bearer incorrect")]
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.call("GET", "/healthz", false, None, &[]).await.0,
        StatusCode::OK
    );
}

#[tokio::test]
async fn streaming_ranges_head_and_download() {
    let f = Fixture::new().await;
    let id = f.id("audio").await;
    let ticket = f.ticket(&id).await;
    for (range, expected, content_range) in [
        ("bytes=2-5", "2345", "bytes 2-5/10"),
        ("bytes=-3", "789", "bytes 7-9/10"),
        ("bytes=8-", "89", "bytes 8-9/10"),
        ("bytes=8-100", "89", "bytes 8-9/10"),
    ] {
        let (status, headers, body) = f
            .call("GET", &ticket, false, None, &[("Range", range)])
            .await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT);
        assert_eq!(body, expected.as_bytes());
        assert_eq!(headers["content-range"], content_range);
        assert_eq!(headers["content-length"], expected.len().to_string());
        assert_eq!(headers["accept-ranges"], "bytes");
        assert_eq!(headers["content-type"], "audio/mpeg");
    }
    let (status, headers, body) = f
        .call("HEAD", &ticket, false, None, &[("Range", "bytes=2-3")])
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.is_empty());
    assert_eq!(headers["content-length"], "10");
    let (_, _, body) = f
        .call(
            "GET",
            &ticket,
            false,
            None,
            &[("Range", "bytes=2-3"), ("If-Range", "unknown")],
        )
        .await;
    assert_eq!(body, b"0123456789");
    // Resuming a download: the validator from the first response keeps the range valid.
    let (_, headers, _) = f.call("GET", &ticket, false, None, &[]).await;
    let etag = headers["etag"].to_str().unwrap().to_owned();
    assert!(etag.starts_with('"') && etag.ends_with('"') && !etag.starts_with("W/"));
    let (status, _, body) = f
        .call(
            "GET",
            &ticket,
            false,
            None,
            &[("Range", "bytes=2-3"), ("If-Range", &etag)],
        )
        .await;
    assert_eq!(status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(body, b"23");
    for range in ["bytes=10-", "bytes=-0", "bytes=0-1,4-5"] {
        let (status, headers, _) = f
            .call("GET", &ticket, false, None, &[("Range", range)])
            .await;
        assert_eq!(status, StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(headers["content-range"], "bytes */10");
    }
    let (status, headers, body) = f
        .call("GET", &format!("/v1/files/{id}/download"), true, None, &[])
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, b"0123456789");
    assert!(
        headers["content-disposition"]
            .to_str()
            .unwrap()
            .starts_with("attachment;")
    );
}

#[tokio::test]
async fn additional_media_formats_keep_their_kind_mime_and_byte_ranges() {
    let f = Fixture::new().await;
    let formats = [
        ("camera.MoV", "video", "video/quicktime"),
        ("legacy.MPEG", "video", "video/mpeg"),
        ("movie.MpG", "video", "video/mpeg"),
        ("camera.M2TS", "video", "video/vnd.dlna.mpeg-tts"),
        ("camera.MTS", "video", "video/vnd.dlna.mpeg-tts"),
        ("recording.TS", "video", "video/mp2t"),
        ("clip.OGV", "video", "video/ogg"),
        ("phone.3GP", "video", "video/3gpp"),
        ("phone.3G2", "video", "video/3gpp2"),
        ("windows.WMV", "video", "video/x-ms-wmv"),
        ("lossless.FLAC", "audio", "audio/flac"),
        ("recording.WAV", "audio", "audio/wav"),
        ("song.OGG", "audio", "audio/ogg"),
        ("recording.AIFC", "audio", "audio/aiff"),
        ("audiobook.M4B", "audio", "audio/mp4"),
        ("song.OGA", "audio", "audio/ogg"),
        ("lossless.APE", "audio", "audio/x-ape"),
        ("windows.WMA", "audio", "audio/x-ms-wma"),
        ("lossless.WV", "audio", "audio/wavpack"),
        ("surround.EAC3", "audio", "audio/eac3"),
        ("surround.DTS", "audio", "audio/vnd.dts"),
        ("voice.AMR", "audio", "audio/amr"),
        ("legacy.AU", "audio", "audio/basic"),
        ("legacy.SND", "audio", "audio/basic"),
    ];
    // The fixtures intentionally test transport and classification, not codec
    // support: an extension cannot establish whether AVPlayer can decode it.
    for (name, _, _) in formats {
        std::fs::write(f.root.join(name), b"0123456789").unwrap();
    }
    f.state.rescan().await.unwrap();
    let (status, _, body) = f
        .call("GET", "/v1/library?limit=500", true, None, &[])
        .await;
    assert_eq!(status, StatusCode::OK);
    let page: Value = serde_json::from_slice(&body).unwrap();
    for (name, kind, mime) in formats {
        let media = page["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["name"] == name)
            .unwrap_or_else(|| panic!("{name} was not indexed"));
        assert_eq!(media["kind"], kind, "{name}");
        let id = media["id"].as_str().unwrap();
        let ticket = f.ticket(id).await;
        let (status, headers, body) = f
            .call("GET", &ticket, false, None, &[("Range", "bytes=2-5")])
            .await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT, "{name}");
        assert_eq!(headers["content-type"], mime, "{name}");
        assert_eq!(headers["content-range"], "bytes 2-5/10", "{name}");
        assert_eq!(headers["content-length"], "4", "{name}");
        assert_eq!(headers["accept-ranges"], "bytes", "{name}");
        assert!(!headers.contains_key("content-disposition"), "{name}");
        assert_eq!(body, b"2345", "{name}");

        let (status, headers, body) = f.call("HEAD", &ticket, false, None, &[]).await;
        assert_eq!(status, StatusCode::OK, "{name}");
        assert_eq!(headers["content-type"], mime, "{name}");
        assert_eq!(headers["content-length"], "10", "{name}");
        assert!(body.is_empty(), "{name}");

        let (status, headers, body) = f
            .call(
                "GET",
                &format!("/v1/files/{id}/download"),
                true,
                None,
                &[("Range", "bytes=-3")],
            )
            .await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT, "{name}");
        assert_eq!(headers["content-type"], mime, "{name}");
        assert_eq!(headers["content-range"], "bytes 7-9/10", "{name}");
        assert!(
            headers["content-disposition"]
                .to_str()
                .unwrap()
                .starts_with("attachment;"),
            "{name}"
        );
        assert_eq!(body, b"789", "{name}");
    }
}

#[tokio::test]
async fn playlists_stay_files_instead_of_becoming_playable_media() {
    let f = Fixture::new().await;
    for name in ["Playlist.M3U", "Playlist.m3u8", "Playlist.pls"] {
        std::fs::write(f.root.join(name), b"#EXTM3U\nsong.mp3\n").unwrap();
    }
    f.state.rescan().await.unwrap();
    let (_, _, body) = f
        .call("GET", "/v1/library?search=Playlist", true, None, &[])
        .await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(page["total"], 3);
    for media in page["items"].as_array().unwrap() {
        assert_eq!(media["kind"], "file");
        let ticket = f.ticket(media["id"].as_str().unwrap()).await;
        let (status, headers, body) = f.call("GET", &ticket, false, None, &[]).await;
        assert_eq!(status, StatusCode::OK);
        assert!(headers.contains_key("content-disposition"));
        assert_eq!(body, b"#EXTM3U\nsong.mp3\n");
    }
    for kind in ["audio", "video"] {
        let (_, _, body) = f
            .call(
                "GET",
                &format!("/v1/library?kind={kind}&search=Playlist"),
                true,
                None,
                &[],
            )
            .await;
        assert_eq!(serde_json::from_slice::<Value>(&body).unwrap()["total"], 0);
    }
}

#[tokio::test]
async fn prepared_playback_is_selected_without_duplicating_original_media() {
    let f = Fixture::new().await;
    std::fs::rename(f.root.join("clip.mp4"), f.root.join("clip.MoV")).unwrap();
    f.state.rescan().await.unwrap();
    for (path, filename, extension, mime, original_mime, prepared, original) in [
        (
            "clip.MoV",
            "playback.mp4",
            "mp4",
            "video/mp4",
            "video/quicktime",
            b"PREPARED-VIDEO".as_slice(),
            b"abcdefghij".as_slice(),
        ),
        (
            "Album/song.mp3",
            "playback.m4a",
            "m4a",
            "audio/mp4",
            "audio/mpeg",
            b"PREPARED-AUDIO!".as_slice(),
            b"0123456789".as_slice(),
        ),
    ] {
        assert!(f.media(path).await.get("playback").is_none());
        f.prepare(path, filename, prepared);
        // The source has not changed, so this also covers the cached-tag path.
        f.state.rescan().await.unwrap();
        let media = f.media(path).await;
        assert_eq!(media["playback"]["file_extension"], extension);
        assert_eq!(media["playback"]["bytes"], prepared.len());
        assert!(media.get("playback_path").is_none());
        let id = media["id"].as_str().unwrap();
        let ticket = f.ticket(id).await;
        let (status, headers, body) = f
            .call("GET", &ticket, false, None, &[("Range", "bytes=2-5")])
            .await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT);
        assert_eq!(headers["content-type"], mime);
        assert_eq!(
            headers["content-range"],
            format!("bytes 2-5/{}", prepared.len())
        );
        assert_eq!(headers["content-length"], "4");
        assert_eq!(body, &prepared[2..6]);
        let (status, headers, body) = f.call("HEAD", &ticket, false, None, &[]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(headers["content-length"], prepared.len().to_string());
        assert_eq!(headers["content-type"], mime);
        assert!(body.is_empty());

        let download = format!("/v1/files/{id}/download");
        let (status, headers, body) = f.call("GET", &download, true, None, &[]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(headers["content-type"], original_mime);
        assert_eq!(body, original);
        let (status, headers, body) = f
            .call(
                "GET",
                &format!("{download}?playback=true"),
                true,
                None,
                &[("Range", "bytes=-3")],
            )
            .await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT);
        assert_eq!(headers["content-type"], mime);
        assert_eq!(body, &prepared[prepared.len() - 3..]);
        assert!(
            headers["content-disposition"]
                .to_str()
                .unwrap()
                .ends_with(&format!("%2E{extension}"))
        );
    }
    let (_, _, body) = f.call("GET", "/v1/library", true, None, &[]).await;
    assert_eq!(serde_json::from_slice::<Value>(&body).unwrap()["total"], 3);
    let (_, _, body) = f.call("GET", "/v1/files", true, None, &[]).await;
    let directory: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(directory["directories"], json!(["Album", "Empty"]));
    let (_, _, body) = f.call("GET", "/v1/storage", true, None, &[]).await;
    let storage: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(storage["file_count"], 3);
    assert_eq!(storage["indexed_bytes"], 20);
}

#[tokio::test]
async fn obsolete_or_malformed_playback_manifests_fall_back_to_the_original() {
    let f = Fixture::new().await;
    let path = "clip.mp4";
    let (directory, valid) = f.prepare(path, "playback.mp4", b"PREPARED-VIDEO");
    f.state.rescan().await.unwrap();
    let id = f.media(path).await["id"].as_str().unwrap().to_owned();
    let ticket = f.ticket(&id).await;
    for (field, bad_value) in [
        ("version", json!(2)),
        ("source_path", json!("different.mp4")),
        ("source_bytes", json!(11)),
        ("source_modified_ns", json!(0)),
        ("filename", json!("../escape.mp4")),
        ("filename", json!("playback.m4a")),
        ("bytes", json!(999)),
        ("bytes", json!(0)),
    ] {
        let mut invalid = valid.clone();
        invalid[field] = bad_value;
        std::fs::write(directory.join("manifest.json"), invalid.to_string()).unwrap();
        // Streaming revalidates even before a rescan removes stale metadata.
        let (status, _, body) = f.call("GET", &ticket, false, None, &[]).await;
        assert_eq!(status, StatusCode::OK, "{field}");
        assert_eq!(body, b"abcdefghij", "{field}");
        f.state.rescan().await.unwrap();
        assert!(f.media(path).await.get("playback").is_none(), "{field}");
    }
    for invalid in [b"not JSON".as_slice(), &vec![b' '; 64 * 1024 + 1]] {
        std::fs::write(directory.join("manifest.json"), invalid).unwrap();
        f.state.rescan().await.unwrap();
        assert!(f.media(path).await.get("playback").is_none());
    }
    std::fs::write(directory.join("manifest.json"), valid.to_string()).unwrap();
    f.state.rescan().await.unwrap();
    assert!(f.media(path).await.get("playback").is_some());
    let source = std::fs::File::open(f.root.join(path)).unwrap();
    let changed_time =
        source.metadata().unwrap().modified().unwrap() + std::time::Duration::from_secs(1);
    source
        .set_times(std::fs::FileTimes::new().set_modified(changed_time))
        .unwrap();
    let (_, _, body) = f.call("GET", &ticket, false, None, &[]).await;
    assert_eq!(body, b"abcdefghij");
    f.state.rescan().await.unwrap();
    assert!(f.media(path).await.get("playback").is_none());
    let (_, headers, body) = f
        .call(
            "GET",
            &format!("/v1/files/{id}/download?playback=true"),
            true,
            None,
            &[],
        )
        .await;
    assert_eq!(headers["content-length"], "10");
    assert_eq!(body, b"abcdefghij");
}

#[tokio::test]
async fn deleting_prepared_files_removes_the_variant_on_the_next_scan() {
    let f = Fixture::new().await;
    let (directory, _) = f.prepare("Album/song.mp3", "playback.m4a", b"PREPARED-AUDIO");
    f.state.rescan().await.unwrap();
    let media = f.media("Album/song.mp3").await;
    assert!(media.get("playback").is_some());
    let id = media["id"].as_str().unwrap();
    let ticket = f.ticket(id).await;
    std::fs::remove_file(directory.join("playback.m4a")).unwrap();
    let (status, headers, body) = f.call("GET", &ticket, false, None, &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "audio/mpeg");
    assert_eq!(body, b"0123456789");
    f.state.rescan().await.unwrap();
    assert!(f.media("Album/song.mp3").await.get("playback").is_none());
    let (status, headers, body) = f
        .call(
            "GET",
            &format!("/v1/files/{id}/download?playback=true"),
            true,
            None,
            &[],
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "audio/mpeg");
    assert_eq!(body, b"0123456789");
}

#[cfg(unix)]
#[tokio::test]
async fn prepared_cache_fifos_cannot_block_scans_or_playback() {
    use std::{ffi::CString, os::unix::ffi::OsStrExt, os::unix::fs::OpenOptionsExt};
    for name in ["manifest.json", "playback.mp4"] {
        let f = Fixture::new().await;
        let (directory, _) = f.prepare("clip.mp4", "playback.mp4", b"PREPARED-VIDEO");
        f.state.rescan().await.unwrap();
        let ticket = f.ticket(&f.id("video").await).await;
        let path = directory.join(name);
        std::fs::remove_file(&path).unwrap();
        let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: c_path is NUL-terminated and lives through mkfifo.
        assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            f.call("GET", &ticket, false, None, &[]),
        )
        .await;
        if response.is_err() {
            let _ = std::fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&path);
        }
        let (status, _, body) = response.expect("cache FIFO must not block streaming");
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, b"abcdefghij");
        let scan = tokio::time::timeout(std::time::Duration::from_secs(2), f.state.rescan()).await;
        if scan.is_err() {
            let _ = std::fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&path);
        }
        scan.expect("cache FIFO must not block scanning").unwrap();
        assert!(f.media("clip.mp4").await.get("playback").is_none());
    }
}

#[cfg(unix)]
#[tokio::test]
async fn prepared_cache_symlinks_are_rejected_before_and_after_indexing() {
    use std::os::unix::fs::symlink;
    for component in ["manifest", "target", "folder", "cache"] {
        let f = Fixture::new().await;
        let (directory, _) = f.prepare("clip.mp4", "playback.mp4", b"PREPARED-VIDEO");
        f.state.rescan().await.unwrap();
        let id = f.media("clip.mp4").await["id"].as_str().unwrap().to_owned();
        assert!(f.media("clip.mp4").await.get("playback").is_some());
        let ticket = f.ticket(&id).await;
        match component {
            "manifest" | "target" => {
                let name = if component == "manifest" {
                    "manifest.json"
                } else {
                    "playback.mp4"
                };
                let outside = f._temp.path().join(name);
                std::fs::rename(directory.join(name), &outside).unwrap();
                symlink(outside, directory.join(name)).unwrap();
            }
            "folder" => {
                let outside = f._temp.path().join("prepared-folder");
                std::fs::rename(&directory, &outside).unwrap();
                symlink(outside, &directory).unwrap();
            }
            "cache" => {
                let cache = f.root.join(".miniply-playback");
                let outside = f._temp.path().join("prepared-cache");
                std::fs::rename(&cache, &outside).unwrap();
                symlink(outside, cache).unwrap();
            }
            _ => unreachable!(),
        }
        for uri in [&ticket, &format!("/v1/files/{id}/download?playback=true")] {
            let (status, headers, body) = f.call("GET", uri, true, None, &[]).await;
            assert_eq!(status, StatusCode::OK, "{component}");
            assert_eq!(headers["content-length"], "10", "{component}");
            assert_eq!(body, b"abcdefghij", "{component}");
        }
        f.state.rescan().await.unwrap();
        assert!(
            f.media("clip.mp4").await.get("playback").is_none(),
            "{component}"
        );
    }
    // Also reject links that stay within the media root, rather than relying
    // solely on the capability's protection against escaping that root.
    let f = Fixture::new().await;
    let (directory, _) = f.prepare("clip.mp4", "playback.mp4", b"PREPARED-VIDEO");
    let inside = f.root.join("inside.mp4");
    std::fs::rename(directory.join("playback.mp4"), &inside).unwrap();
    symlink(inside, directory.join("playback.mp4")).unwrap();
    f.state.rescan().await.unwrap();
    assert!(f.media("clip.mp4").await.get("playback").is_none());
}

#[tokio::test]
async fn tickets_reject_expiry_tampering_and_wrong_file() {
    let f = Fixture::new().await;
    let audio = f.id("audio").await;
    let video = f.id("video").await;
    let ticket = f.ticket(&audio).await;
    let tampered = ticket.replace(&audio, &video);
    assert_eq!(
        f.call("GET", &tampered, false, None, &[]).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.call("GET", &(ticket.clone() + "0"), false, None, &[])
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    let expires = miniply_server::catalog::now() - 1;
    let mut mac = Hmac::<Sha256>::new_from_slice(&Sha256::digest(TOKEN)).unwrap();
    mac.update(format!("miniply-stream-v1\n{audio}\n{expires}").as_bytes());
    let signature = hex::encode(mac.finalize().into_bytes());
    assert_eq!(
        f.call(
            "GET",
            &format!("/stream/{audio}?expires={expires}&signature={signature}"),
            false,
            None,
            &[]
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    // Rotating the master token immediately revokes existing playback tickets.
    let new_state = AppState::new(
        f.root.clone(),
        "rotated-0123456789-abcdefghijklmnopqrstuvwxyz",
        f.database.clone(),
    )
    .await
    .unwrap();
    assert_eq!(
        call(&router(new_state), "GET", &ticket, false, None, &[])
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn browsing_pagination_and_rescan() {
    let f = Fixture::new().await;
    let (_, _, body) = f
        .call("GET", "/v1/library?limit=1&offset=1", true, None, &[])
        .await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(page["total"], 3);
    assert_eq!(page["offset"], 1);
    assert_eq!(page["items"].as_array().unwrap().len(), 1);
    assert_eq!(page["items"][0]["path"], "clip.mp4");
    let (_, _, body) = f
        .call(
            "GET",
            "/v1/library?kind=audio&search=SONG&limit=1",
            true,
            None,
            &[],
        )
        .await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(page["total"], 1);
    assert_eq!(page["items"][0]["path"], "Album/song.mp3");
    let (_, _, body) = f.call("GET", "/v1/files", true, None, &[]).await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(page["directories"], json!(["Album", "Empty"]));
    assert_eq!(
        f.call("GET", "/v1/files?path=..", true, None, &[]).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        f.call("GET", "/v1/files?path=%2Fetc", true, None, &[])
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    std::fs::remove_file(f.root.join("clip.mp4")).unwrap();
    std::fs::write(f.root.join("new.mov"), b"new").unwrap();
    assert_eq!(
        f.call("POST", "/v1/scan", true, None, &[]).await.0,
        StatusCode::NO_CONTENT
    );
    let (_, _, body) = f
        .call("GET", "/v1/library?kind=video", true, None, &[])
        .await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(page["items"][0]["name"], "new.mov");
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_cannot_escape_even_after_indexing() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new().await;
    let outside = f._temp.path().join("private.mp3");
    std::fs::write(&outside, b"private-secret").unwrap();
    symlink(&outside, f.root.join("link.mp3")).unwrap();
    f.state.rescan().await.unwrap();
    let (_, _, body) = f
        .call("GET", "/v1/library?search=link", true, None, &[])
        .await;
    assert_eq!(serde_json::from_slice::<Value>(&body).unwrap()["total"], 0);
    let id = f.id("audio").await;
    let ticket = f.ticket(&id).await;
    std::fs::remove_file(f.root.join("Album/song.mp3")).unwrap();
    symlink(&outside, f.root.join("Album/song.mp3")).unwrap();
    let (status, _, body) = f.call("GET", &ticket, false, None, &[]).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(!String::from_utf8_lossy(&body).contains("private-secret"));
    std::fs::remove_file(f.root.join("Album/song.mp3")).unwrap();
    std::fs::remove_dir(f.root.join("Album")).unwrap();
    symlink(f._temp.path(), f.root.join("Album")).unwrap();
    assert_eq!(
        f.call("GET", &ticket, false, None, &[]).await.0,
        StatusCode::NOT_FOUND
    );
}

#[cfg(unix)]
#[tokio::test]
async fn replacing_indexed_files_with_a_fifo_does_not_block_streaming() {
    use std::{ffi::CString, os::unix::ffi::OsStrExt, os::unix::fs::OpenOptionsExt};

    let f = Fixture::new().await;
    let id = f.id("audio").await;
    let ticket = f.ticket(&id).await;
    let path = f.root.join("Album/song.mp3");
    std::fs::remove_file(&path).unwrap();
    let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: c_path is a live, NUL-terminated path; mkfifo retains no pointer.
    assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);

    for (method, uri) in [
        ("GET", ticket.clone()),
        ("HEAD", ticket),
        ("GET", format!("/v1/files/{id}/download")),
    ] {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            f.call(method, &uri, true, None, &[]),
        )
        .await;
        if result.is_err() {
            // Unblock a regressed blocking open so the test runtime can shut down.
            let _ = std::fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&path);
        }
        assert_eq!(
            result
                .expect("opening a replaced media file must not wait for a FIFO writer")
                .0,
            StatusCode::NOT_FOUND,
        );
    }
}

#[tokio::test]
async fn playlists_and_progress_survive_restart() {
    let f = Fixture::new().await;
    let id = f.id("audio").await;
    let value = json!({"name":"Abendmusik","media_ids":[id]});
    let (status, _, body) = f
        .call("POST", "/v1/playlists", true, Some(value), &[])
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let playlist: Value = serde_json::from_slice(&body).unwrap();
    let playlist_id = playlist["id"].as_str().unwrap();
    assert_eq!(
        f.call(
            "PUT",
            &format!("/v1/progress/{id}"),
            true,
            Some(json!({"seconds":42.5})),
            &[]
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    let state = AppState::new(f.root.clone(), TOKEN, f.database.clone())
        .await
        .unwrap();
    let app = router(state);
    let (_, _, body) = call(&app, "GET", "/v1/playlists", true, None, &[]).await;
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()[0]["name"],
        "Abendmusik"
    );
    let (_, _, body) = call(&app, "GET", &format!("/v1/progress/{id}"), true, None, &[]).await;
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["seconds"],
        42.5
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            &format!("/v1/playlists/{playlist_id}"),
            true,
            None,
            &[]
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            &format!("/v1/playlists/{playlist_id}"),
            true,
            None,
            &[]
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn newest_position_wins_even_when_sent_late() {
    let f = Fixture::new().await;
    let id = f.id("video").await;
    let path = format!("/v1/progress/{id}");
    let put = |seconds: f64, at: u64| json!({"seconds": seconds, "updated_at": at});
    // The iPad saves minute 20 now; the iPhone sends its offline minute 14 from earlier.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    for (seconds, at) in [(1200.0, now - 60), (840.0, now - 600)] {
        let (status, _, _) = f
            .call("PUT", &path, true, Some(put(seconds, at)), &[])
            .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    let (_, _, body) = f.call("GET", &path, true, None, &[]).await;
    let saved: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(saved["seconds"], 1200.0);
    // A newer one replaces it; a time in the future counts as now.
    f.call("PUT", &path, true, Some(put(1300.0, now + 86_400)), &[])
        .await;
    let (_, _, body) = f.call("GET", &path, true, None, &[]).await;
    let saved: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(saved["seconds"], 1300.0);
    assert!(saved["updated_at"].as_u64().unwrap() <= now + 5);
    // Older apps send no time: it counts as now.
    f.call("PUT", &path, true, Some(json!({"seconds": 1400.0})), &[])
        .await;
    let (_, _, body) = f.call("GET", &path, true, None, &[]).await;
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["seconds"],
        1400.0
    );
}

#[tokio::test]
async fn rejects_invalid_updates_and_keeps_database_private() {
    let f = Fixture::new().await;
    let id = f.id("audio").await;
    let video = f.id("video").await;
    for value in [
        json!({"name":" ","media_ids":[]}),
        json!({"name":"bad","media_ids":[video]}),
    ] {
        assert_eq!(
            f.call("POST", "/v1/playlists", true, Some(value), &[])
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(
        f.call(
            "PUT",
            &format!("/v1/progress/{id}"),
            true,
            Some(json!({"seconds":-1})),
            &[]
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert!(
        AppState::new(f.root.clone(), TOKEN, f.root.join("state.sqlite"))
            .await
            .is_err()
    );
    assert!(
        AppState::new(f.root.clone(), "short", f.database.clone())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn zero_byte_files() {
    let f = Fixture::new().await;
    let id = f.id("file").await;
    let ticket = f.ticket(&id).await;
    let (status, headers, body) = f.call("GET", &ticket, false, None, &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-length"], "0");
    assert!(body.is_empty());
    assert_eq!(
        f.call("GET", &ticket, false, None, &[("Range", "bytes=0-")])
            .await
            .0,
        StatusCode::RANGE_NOT_SATISFIABLE
    );
}

#[tokio::test]
async fn folders_become_albums_with_covers_and_series_get_seasons() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("media");
    let album = root.join("Musik/Linkin Park/Hybrid Theory");
    std::fs::create_dir_all(album.join("CD2")).unwrap();
    std::fs::write(album.join("01 Papercut.mp3"), b"audio-one").unwrap();
    std::fs::write(album.join("CD2/01 Bonus.mp3"), b"audio-two").unwrap();
    std::fs::write(album.join("IMG_0001.jpg"), b"other-image").unwrap();
    std::fs::write(album.join("cover.jpg"), b"\xFF\xD8cover-image").unwrap();
    std::fs::write(root.join("Musik/loose.mp3"), b"loose").unwrap();
    for season in ["Season 1", "Season 12", "Season 4"] {
        let dir = root.join("Serien/Two and a Half Men").join(season);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("S01E02 - Folge.mp4"), b"video").unwrap();
    }
    std::fs::write(root.join("Serien/Two and a Half Men/poster.png"), b"poster").unwrap();
    let state = AppState::new(root.clone(), TOKEN, temp.path().join("db.sqlite"))
        .await
        .unwrap();
    let app = router(state);
    let (_, _, body) = call(&app, "GET", "/v1/library?limit=500", true, None, &[]).await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    let item = |path: &str| {
        page["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["path"] == path)
            .unwrap_or_else(|| panic!("{path}"))
            .clone()
    };
    let cover_id = hex::encode(Sha256::digest(
        "Musik/Linkin Park/Hybrid Theory/cover.jpg".as_bytes(),
    ));
    let track = item("Musik/Linkin Park/Hybrid Theory/01 Papercut.mp3");
    assert_eq!(track["album"], "Hybrid Theory");
    assert_eq!(track["album_key"], "Musik/Linkin Park/Hybrid Theory");
    assert_eq!(track["artist"], "Linkin Park");
    assert_eq!(track["album_artist"], "Linkin Park");
    assert_eq!(track["cover_id"], cover_id.as_str());
    let bonus = item("Musik/Linkin Park/Hybrid Theory/CD2/01 Bonus.mp3");
    assert_eq!(bonus["album_key"], "Musik/Linkin Park/Hybrid Theory");
    assert_eq!(bonus["disc_number"], 2);
    let loose = item("Musik/loose.mp3");
    assert!(loose.get("album_key").is_none());
    for (season, number) in [("Season 1", 1), ("Season 12", 12), ("Season 4", 4)] {
        let episode = item(&format!(
            "Serien/Two and a Half Men/{season}/S01E02 - Folge.mp4"
        ));
        assert_eq!(episode["series_key"], "Serien/Two and a Half Men");
        assert_eq!(episode["season_folder"], season);
        assert_eq!(episode["season"], number);
        assert_eq!(episode["episode"], 2);
        assert_eq!(
            episode["cover_id"],
            hex::encode(Sha256::digest(
                "Serien/Two and a Half Men/poster.png".as_bytes()
            ))
            .as_str()
        );
    }

    let (status, _, body) = call(&app, "GET", "/v1/metadata", true, None, &[]).await;
    assert_eq!(status, StatusCode::OK);
    let metadata: Value = serde_json::from_slice(&body).unwrap();
    assert!(
        metadata["covers"].as_array().unwrap().contains(
            &json!({"directory": "Musik/Linkin Park/Hybrid Theory", "artwork": cover_id})
        )
    );
    assert!(metadata["albums"].as_array().unwrap().is_empty());

    let (status, headers, body) = call(
        &app,
        "GET",
        &format!("/v1/artwork/{cover_id}"),
        true,
        None,
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "image/jpeg");
    assert_eq!(headers["cache-control"], "private, max-age=604800");
    assert_eq!(body, b"\xFF\xD8cover-image");
    let video_id = item("Serien/Two and a Half Men/Season 1/S01E02 - Folge.mp4")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    for path in [
        format!("/v1/artwork/{video_id}"),
        "/v1/artwork/web-0123".into(),
        "/v1/artwork/web-0123456789abcdef0123456789abcdef".into(),
    ] {
        assert_eq!(
            call(&app, "GET", &path, true, None, &[]).await.0,
            StatusCode::NOT_FOUND,
            "{path}"
        );
    }
    assert_eq!(
        call(
            &app,
            "GET",
            &format!("/v1/artwork/{cover_id}"),
            false,
            None,
            &[]
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn adaptive_copies_are_served_only_with_a_valid_ticket() {
    use std::os::unix::fs::MetadataExt;
    let f = Fixture::new().await;
    let id = f.id("video").await;
    let source = std::fs::metadata(f.root.join("clip.mp4")).unwrap();
    let copy = f.root.join(".miniply-hls").join(&id);
    std::fs::create_dir_all(copy.join("v0")).unwrap();
    std::fs::write(copy.join("master.m3u8"), b"#EXTM3U\n").unwrap();
    std::fs::write(copy.join("v0/index.m3u8"), b"#EXTM3U\n").unwrap();
    std::fs::write(copy.join("v0/seg00000.ts"), b"segment").unwrap();
    std::fs::write(copy.join("v0/other.bin"), b"nope").unwrap();
    let nanos = source.mtime() as u128 * 1_000_000_000 + source.mtime_nsec() as u128;
    let write_manifest =
        |bytes: u64| {
            std::fs::write(
            copy.join("manifest.json"),
            json!({"version": 1, "revision": 1, "source_path": "clip.mp4", "source_bytes": bytes,
                   "source_modified_ns": 0})
                .to_string()
                .replace("\"source_modified_ns\":0", &format!("\"source_modified_ns\":{nanos}")),
        )
        .unwrap();
        };
    let ticket = |f: &Fixture, id: String| {
        let app = f.app.clone();
        async move {
            let (_, _, body) = call(
                &app,
                "POST",
                &format!("/v1/media/{id}/ticket"),
                true,
                None,
                &[],
            )
            .await;
            serde_json::from_slice::<Value>(&body).unwrap()
        }
    };
    // A manifest of another file version counts as no copy.
    write_manifest(9);
    assert_eq!(
        f.call("POST", "/v1/scan", true, None, &[]).await.0,
        StatusCode::NO_CONTENT
    );
    assert!(ticket(&f, id.clone()).await.get("hls_path").is_none());
    write_manifest(10);
    assert_eq!(
        f.call("POST", "/v1/scan", true, None, &[]).await.0,
        StatusCode::NO_CONTENT
    );
    let (_, _, body) = f
        .call("GET", "/v1/library?kind=video", true, None, &[])
        .await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(page["items"][0]["hls"], true);
    assert_eq!(page["total"], 1, "the copy must not appear in the library");

    let ticketed = ticket(&f, id.clone()).await;
    let master = ticketed["hls_path"].as_str().unwrap().to_owned();
    let (status, headers, body) = f.call("GET", &master, false, None, &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "application/vnd.apple.mpegurl");
    assert_eq!(body, b"#EXTM3U\n");
    let base = master.strip_suffix("master.m3u8").unwrap();
    let (status, headers, body) = f
        .call("GET", &format!("{base}v0/seg00000.ts"), false, None, &[])
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "video/mp2t");
    assert_eq!(body, b"segment");
    for name in [
        "manifest.json",
        "v0/other.bin",
        "..%2F..%2Fclip.mp4",
        "v0/../../manifest.json",
    ] {
        let (status, _, _) = f
            .call("GET", &format!("{base}{name}"), false, None, &[])
            .await;
        assert_ne!(status, StatusCode::OK, "{name}");
    }
    // Tampered or expired tickets get nothing.
    let mut parts: Vec<&str> = master.split('/').collect();
    let signature = parts[5].to_owned();
    let other = if signature.starts_with('0') { "1" } else { "0" }.to_owned() + &signature[1..];
    parts[5] = &other;
    assert_eq!(
        f.call("GET", &parts.join("/"), false, None, &[]).await.0,
        StatusCode::UNAUTHORIZED
    );
    parts[5] = &signature;
    parts[4] = "1";
    assert_eq!(
        f.call("GET", &parts.join("/"), false, None, &[]).await.0,
        StatusCode::UNAUTHORIZED
    );
    // The signature of one video opens no other.
    let song = f.id("audio").await;
    let foreign = master.replace(&id, &song);
    assert_eq!(
        f.call("GET", &foreign, false, None, &[]).await.0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn personal_state_merges_between_devices() {
    let f = Fixture::new().await;
    let a = "a".repeat(64);
    let b = "b".repeat(64);
    let sync = |body: Value| async {
        f.call("POST", "/v1/personal/sync", true, Some(body), &[])
            .await
    };
    let (status, _, _) = f
        .call(
            "POST",
            "/v1/personal/sync",
            false,
            Some(json!({"device": "x"})),
            &[],
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, _) = sync(json!({
        "device": "phone",
        "favorites": [{"id": a, "on": true, "at": 100.0}, {"id": b, "on": true, "at": 100.0}],
        "watched": [{"id": a, "on": true, "at": 50.0}],
        "plays": [{"id": a, "count": 3}],
        "last_played": [{"id": a, "at": 500.0}]
    }))
    .await;
    assert_eq!(status, StatusCode::OK);
    // The tablet removes a favourite later, has older data for the other and
    // counts its own plays. Its older last play time does not win.
    let (status, _, body) = sync(json!({
        "device": "tablet",
        "favorites": [{"id": a, "on": false, "at": 200.0}, {"id": b, "on": false, "at": 10.0}],
        "plays": [{"id": a, "count": 2}],
        "last_played": [{"id": a, "at": 400.0}]
    }))
    .await;
    assert_eq!(status, StatusCode::OK);
    let merged: Value = serde_json::from_slice(&body).unwrap();
    let flag = |list: &str, id: &str| {
        merged[list]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == id)
            .unwrap()
            .clone()
    };
    assert_eq!(flag("favorites", &a)["on"], false);
    assert_eq!(flag("favorites", &b)["on"], true);
    assert_eq!(flag("watched", &a)["on"], true);
    assert_eq!(flag("plays", &a)["count"], 5);
    assert_eq!(flag("last_played", &a)["at"], 500.0);
    // Syncing again changes nothing, and a device never loses plays.
    let (_, _, body) = sync(json!({"device": "phone", "plays": [{"id": a, "count": 1}]})).await;
    let again: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(again["plays"][0]["count"], 5);
    // Only changes since the last answer come back.
    let cursor = again["cursor"].as_i64().unwrap();
    let (_, _, body) = sync(json!({"device": "phone", "since": cursor})).await;
    let quiet: Value = serde_json::from_slice(&body).unwrap();
    assert!(quiet["cursor"].as_i64().unwrap() > cursor);
    for list in ["favorites", "watched", "plays", "last_played"] {
        assert_eq!(quiet[list].as_array().unwrap().len(), 0, "{list}");
    }
    let cursor = quiet["cursor"].as_i64().unwrap();
    sync(json!({"device": "tablet", "plays": [{"id": a, "count": 4}],
                "watched": [{"id": b, "on": true, "at": 300.0}]}))
    .await;
    let (_, _, body) = sync(json!({"device": "phone", "since": cursor})).await;
    let changed: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(changed["plays"], json!([{"id": a, "count": 7}]));
    assert_eq!(changed["watched"][0]["id"], json!(b));
    assert_eq!(changed["favorites"].as_array().unwrap().len(), 0);
    // A clock far in the future cannot block all later changes.
    let (_, _, body) =
        sync(json!({"device": "phone", "watched": [{"id": b, "on": true, "at": 9e15}]})).await;
    let clamped: Value = serde_json::from_slice(&body).unwrap();
    assert!(
        clamped["watched"]
            .as_array()
            .unwrap()
            .iter()
            .all(|w| w["at"].as_f64().unwrap() < 1e12)
    );
    for bad in [
        json!({"device": "../x"}),
        json!({"device": "ok", "plays": [{"id": "../../etc", "count": 1}]}),
        json!({"device": "ok", "favorites": [{"id": "ABC", "on": true, "at": 1.0}]}),
    ] {
        assert_eq!(sync(bad).await.0, StatusCode::BAD_REQUEST);
    }
}

#[tokio::test]
async fn subtitles_lyrics_and_uploads() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("media");
    std::fs::create_dir_all(root.join("Filme")).unwrap();
    std::fs::create_dir_all(root.join("Musik/Album")).unwrap();
    std::fs::write(root.join("Filme/Film.mp4"), b"video").unwrap();
    std::fs::write(
        root.join("Filme/Film.de.srt"),
        b"1\n00:00:01,000 --> 00:00:02,000\nGr\xFC\xDFe\n",
    )
    .unwrap();
    std::fs::write(root.join("Musik/Album/01 Lied.mp3"), b"audio").unwrap();
    std::fs::write(
        root.join("Musik/Album/01 Lied.lrc"),
        "[00:01.00] eins\n[00:02.00] zwei\n[00:03.00] drei\n",
    )
    .unwrap();
    // SAFETY: tests in this file do not read MINIPLY_* variables concurrently
    // except this one, which only enables uploads and disables online lookups.
    unsafe {
        std::env::set_var("MINIPLY_UPLOADS", "1");
        std::env::set_var("MINIPLY_ONLINE_METADATA", "0");
    }
    let state = AppState::new(root.clone(), TOKEN, temp.path().join("db.sqlite"))
        .await
        .unwrap();
    let app = router(state.clone());
    let (_, _, body) = call(&app, "GET", "/v1/library?limit=500", true, None, &[]).await;
    let page: Value = serde_json::from_slice(&body).unwrap();
    let find = |path: &str| {
        page["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["path"] == path)
            .unwrap()
            .clone()
    };
    let film = find("Filme/Film.mp4");
    assert_eq!(film["subtitles"][0]["language"], "de");
    assert_eq!(film["subtitles"][0]["label"], "Deutsch");
    let subtitle_id = film["subtitles"][0]["id"].as_str().unwrap().to_owned();
    let (status, headers, body) = call(
        &app,
        "GET",
        &format!("/v1/subtitles/{subtitle_id}"),
        true,
        None,
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "text/vtt; charset=utf-8");
    let text = String::from_utf8(body).unwrap();
    assert!(text.starts_with("WEBVTT"));
    assert!(text.contains("00:00:01.000 --> 00:00:02.000"));
    assert!(text.contains("Grüße"));

    let song = find("Musik/Album/01 Lied.mp3");
    assert_eq!(song["has_lyrics"], true);
    let id = song["id"].as_str().unwrap();
    let (status, _, body) = call(&app, "GET", &format!("/v1/lyrics/{id}"), true, None, &[]).await;
    assert_eq!(status, StatusCode::OK);
    let lyrics: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(lyrics["source"], "file");
    assert!(
        lyrics["synced"]
            .as_str()
            .unwrap()
            .contains("[00:02.00] zwei")
    );
    let film_id = film["id"].as_str().unwrap();
    assert_eq!(
        call(
            &app,
            "GET",
            &format!("/v1/lyrics/{film_id}"),
            true,
            None,
            &[]
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );

    let upload = |path: &str, data: &'static [u8], authenticated: bool| {
        let mut request = Request::builder().method("POST").uri(path);
        if authenticated {
            request = request.header("Authorization", format!("Bearer {TOKEN}"));
        }
        let request = request.body(Body::from(data)).unwrap();
        let app = app.clone();
        async move { app.oneshot(request).await.unwrap().status() }
    };
    let target = "/v1/upload?path=Musik%2FNeues%20Album&name=01%20Neu.mp3";
    assert_eq!(upload(target, b"x", false).await, StatusCode::UNAUTHORIZED);
    // Larger than the normal 64 KiB JSON limit.
    let big: &'static [u8] = Box::leak(vec![7u8; 200 * 1024].into_boxed_slice());
    assert_eq!(upload(target, big, true).await, StatusCode::CREATED);
    assert_eq!(
        std::fs::read(root.join("Musik/Neues Album/01 Neu.mp3"))
            .unwrap()
            .len(),
        200 * 1024
    );
    assert_eq!(upload(target, b"replace", true).await, StatusCode::CONFLICT);
    assert_eq!(
        std::fs::read(root.join("Musik/Neues Album/01 Neu.mp3"))
            .unwrap()
            .len(),
        200 * 1024
    );
    for bad in [
        "/v1/upload?path=..%2F..&name=x.mp3",
        "/v1/upload?path=Musik&name=.hidden.mp3",
        "/v1/upload?path=Musik&name=a%2Fb.mp3",
    ] {
        assert_eq!(
            upload(bad, b"x", true).await,
            StatusCode::BAD_REQUEST,
            "{bad}"
        );
    }
    assert!(!temp.path().join("x.mp3").exists());

    // Resumable upload in parts, with a dropped connection in between.
    let id = "6f1c2a10-7b1e-4a53-9c11-2f6f3f1d0a01";
    let put = |offset: usize, data: &'static [u8]| {
        let app = app.clone();
        let uri =
            format!("/v1/uploads/{id}?offset={offset}&bytes=10&path=Musik%2FTeile&name=teile.mp3");
        async move {
            let request = Request::builder()
                .method("PUT")
                .uri(uri)
                .header("authorization", format!("Bearer {TOKEN}"))
                .body(Body::from(data))
                .unwrap();
            app.oneshot(request).await.unwrap().status()
        }
    };
    let received = |app: Router| async move {
        let (status, _, body) =
            call(&app, "GET", &format!("/v1/uploads/{id}"), true, None, &[]).await;
        assert_eq!(status, StatusCode::OK);
        serde_json::from_slice::<Value>(&body).unwrap()["received"]
            .as_u64()
            .unwrap()
    };
    assert_eq!(received(app.clone()).await, 0);
    let (status, _, _) = call(&app, "GET", &format!("/v1/uploads/{id}"), false, None, &[]).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(put(0, b"0123").await, StatusCode::OK);
    assert_eq!(received(app.clone()).await, 4);
    assert!(!root.join("Musik/Teile/teile.mp3").exists());
    assert_eq!(put(2, b"xx").await, StatusCode::PRECONDITION_FAILED);
    assert_eq!(received(app.clone()).await, 4);
    assert_eq!(put(4, b"456789").await, StatusCode::CREATED);
    assert_eq!(
        std::fs::read(root.join("Musik/Teile/teile.mp3")).unwrap(),
        b"0123456789"
    );
    assert_eq!(received(app.clone()).await, 0);
    // The answer to the last part got lost: asking again hears "done".
    assert_eq!(put(0, b"0123").await, StatusCode::CREATED);
    assert_eq!(
        std::fs::read(root.join("Musik/Teile/teile.mp3")).unwrap(),
        b"0123456789"
    );
    // Another upload to the same name is a real conflict.
    let rival = "6f1c2a10-7b1e-4a53-9c11-2f6f3f1d0a03";
    let request = Request::builder()
        .method("PUT")
        .uri(format!(
            "/v1/uploads/{rival}?offset=0&bytes=10&path=Musik%2FTeile&name=teile.mp3"
        ))
        .header("authorization", format!("Bearer {TOKEN}"))
        .body(Body::from("0"))
        .unwrap();
    assert_eq!(
        app.clone().oneshot(request).await.unwrap().status(),
        StatusCode::CONFLICT
    );
    // More than announced, a bad ID and a bad target change nothing.
    let other = "6f1c2a10-7b1e-4a53-9c11-2f6f3f1d0a02";
    let send = |uri: String| {
        let app = app.clone();
        async move {
            let request = Request::builder()
                .method("PUT")
                .uri(uri)
                .header("authorization", format!("Bearer {TOKEN}"))
                .body(Body::from("abc"))
                .unwrap();
            app.oneshot(request).await.unwrap().status()
        }
    };
    assert_eq!(
        send(format!(
            "/v1/uploads/{other}?offset=0&bytes=2&path=Musik&name=a.mp3"
        ))
        .await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        send("/v1/uploads/..%2F..%2Fx?offset=0&bytes=3&path=Musik&name=a.mp3".into()).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        send(format!(
            "/v1/uploads/{other}?offset=0&bytes=3&path=..%2F..&name=a.mp3"
        ))
        .await,
        StatusCode::BAD_REQUEST
    );
    let (status, _, _) = call(
        &app,
        "DELETE",
        &format!("/v1/uploads/{other}"),
        true,
        None,
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(!root.join("Musik/a.mp3").exists());

    let (status, _, _) = call(
        &app,
        "DELETE",
        &format!("/v1/uploads/{id}"),
        true,
        None,
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let leftovers = std::fs::read_dir(root.join(".miniply-upload"))
        .unwrap()
        .count();
    assert_eq!(leftovers, 0);
    unsafe {
        std::env::remove_var("MINIPLY_UPLOADS");
        std::env::remove_var("MINIPLY_ONLINE_METADATA");
    }
}

#[tokio::test]
async fn music_requests_wait_for_the_service() {
    let f = Fixture::new().await;
    let new = json!({"kind": "album", "item_id": 42, "title": "Views", "artist": "Drake"});
    let (status, _, _) = f.call("GET", "/v1/music/jobs", true, None, &[]).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let jobs = f.database.parent().unwrap().join("music-jobs");
    std::fs::create_dir(&jobs).unwrap();
    let (status, _, _) = f.call("GET", "/v1/music/jobs", false, None, &[]).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, body) = f
        .call("POST", "/v1/music/jobs", true, Some(new.clone()), &[])
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let job: Value = serde_json::from_slice(&body).unwrap();
    let id = job["id"].as_str().unwrap().to_owned();
    assert_eq!(job["state"], "queued");

    // The same request again is the same job.
    let (status, _, body) = f.call("POST", "/v1/music/jobs", true, Some(new), &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(serde_json::from_slice::<Value>(&body).unwrap()["id"], *id);
    let bad = json!({"kind": "playlist", "item_id": 1, "title": "x"});
    let (status, _, _) = f.call("POST", "/v1/music/jobs", true, Some(bad), &[]).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Progress from the service; a running job is only asked to stop.
    std::fs::write(
        jobs.join(format!("{id}.state.json")),
        json!({"state": "running", "done": 3, "total": 20, "current": "Hype", "missing": ["9"]})
            .to_string(),
    )
    .unwrap();
    std::fs::write(jobs.join("heartbeat"), []).unwrap();
    let (_, _, body) = f.call("GET", "/v1/music/jobs", true, None, &[]).await;
    let list: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(list["service_online"], true);
    assert_eq!(list["jobs"][0]["done"], 3);
    assert_eq!(list["jobs"][0]["title"], "Views");
    let path = format!("/v1/music/jobs/{id}");
    let (status, _, _) = f.call("DELETE", &path, true, None, &[]).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert!(jobs.join(format!("{id}.cancel")).exists());

    // A finished job is forgotten; other names never reach the file system.
    std::fs::write(
        jobs.join(format!("{id}.state.json")),
        json!({"state": "done"}).to_string(),
    )
    .unwrap();
    let (status, _, _) = f.call("DELETE", &path, true, None, &[]).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(!jobs.join(format!("{id}.json")).exists());
    let (status, _, _) = f
        .call("DELETE", "/v1/music/jobs/..%2Fstate", true, None, &[])
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn deleting_moves_files_to_the_trash() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("media");
    let album = root.join("Musik/Künstler - Album");
    let show = root.join("Serien/Show/Staffel 1");
    std::fs::create_dir_all(&album).unwrap();
    std::fs::create_dir_all(&show).unwrap();
    std::fs::write(album.join("01 A.mp3"), b"a").unwrap();
    std::fs::write(album.join("01 A.lrc"), b"[00:01]a").unwrap();
    std::fs::write(album.join("02 B.mp3"), b"b").unwrap();
    std::fs::write(album.join("cover.jpg"), b"c").unwrap();
    std::fs::write(album.join(".DS_Store"), b"d").unwrap();
    std::fs::write(show.join("S01E01.mp4"), b"e").unwrap();
    std::fs::write(show.join("S01E01.de.srt"), b"f").unwrap();
    std::fs::write(root.join("Serien/Show/notes.pdf"), b"g").unwrap();
    let state = AppState::new(root.clone(), TOKEN, temp.path().join("db.sqlite"))
        .await
        .unwrap();

    let id = |path: &str| hex::encode(Sha256::digest(path.as_bytes()));
    let call = |app: Router, ids: Vec<String>, token: &'static str| async move {
        let request = Request::builder()
            .method("POST")
            .uri("/v1/media/delete")
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/json")
            .body(Body::from(json!({ "ids": ids }).to_string()))
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        let status = response.status();
        let body = to_bytes(response.into_body(), 1 << 16).await.unwrap();
        (
            status,
            serde_json::from_slice::<Value>(&body).unwrap_or(Value::Null),
        )
    };
    let a = id("Musik/Künstler - Album/01 A.mp3");
    let b = id("Musik/Künstler - Album/02 B.mp3");
    let episode = id("Serien/Show/Staffel 1/S01E01.mp4");

    // Off by default, and never without the token.
    let (status, _) = call(router(state.clone()), vec![a.clone()], TOKEN).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(album.join("01 A.mp3").exists());
    let app = router(state.with_deletes());
    let (status, _) = call(app.clone(), vec![a.clone()], "wrong-token").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(album.join("01 A.mp3").exists());

    // One song: the lyrics go with it, the album stays.
    let unknown = "0".repeat(64);
    let (status, body) = call(app.clone(), vec![a.clone(), unknown], TOKEN).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"deleted": 1, "failed": 0}));
    assert!(!album.join("01 A.mp3").exists() && !album.join("01 A.lrc").exists());
    assert!(album.join("02 B.mp3").exists() && album.join("cover.jpg").exists());
    let trash = root.join(".miniply-papierkorb");
    let batch = std::fs::read_dir(&trash)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert!(batch.join("Musik/Künstler - Album/01 A.mp3").exists());

    // The last song takes the album folder and its cover along, not "Musik".
    let (_, body) = call(app.clone(), vec![b], TOKEN).await;
    assert_eq!(body["deleted"], 1);
    assert!(!album.exists());
    assert!(root.join("Musik").exists());

    // A folder with other files stays.
    let (_, body) = call(app.clone(), vec![episode], TOKEN).await;
    assert_eq!(body["deleted"], 1);
    assert!(!show.exists());
    assert!(root.join("Serien/Show/notes.pdf").exists());

    // A file that is no longer known is not an error, other kinds are refused.
    let (status, body) = call(app.clone(), vec![a], TOKEN).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["deleted"], 0);
    let pdf = id("Serien/Show/notes.pdf");
    let (_, body) = call(app, vec![pdf], TOKEN).await;
    assert_eq!(body["deleted"], 0);
    assert!(root.join("Serien/Show/notes.pdf").exists());
}
