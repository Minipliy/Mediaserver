//! The browser player under `/web/`: three files built into the program.
//!
//! It signs in with the same token as the app and uses only the API below
//! `/v1/` and the signed `/stream/` addresses, so it needs no session of its
//! own. The token stays in the browser; nothing here reads it.

use axum::{
    Router,
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Redirect, Response},
    routing::get,
};

const INDEX: &str = include_str!("../web/index.html");
const SCRIPT: &str = include_str!("../web/app.js");
const STYLE: &str = include_str!("../web/app.css");
const ICON: &[u8] = include_bytes!("../web/icon.png");

/// Only the player's own files; pictures and subtitles arrive as blobs (catalog
/// covers on an artist page come straight from Apple's image host), media
/// from the same address.
const POLICY: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: https://*.mzstatic.com; \
media-src 'self' blob:; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; \
frame-ancestors 'none'";

fn file(body: impl IntoResponse, kind: &'static str) -> Response {
    let mut response = (StatusCode::OK, body).into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(kind));
    // Revalidate every time, so an update of the server reaches the browser at once.
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(POLICY),
    );
    headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    response
}

pub fn routes<S: Clone + Send + Sync + 'static>() -> Router<S> {
    Router::new()
        .route("/", get(|| async { Redirect::temporary("/web/") }))
        .route("/web", get(|| async { Redirect::permanent("/web/") }))
        .route(
            "/web/",
            get(|| async { file(INDEX, "text/html; charset=utf-8") }),
        )
        .route(
            "/web/app.js",
            get(|| async { file(SCRIPT, "text/javascript; charset=utf-8") }),
        )
        .route(
            "/web/app.css",
            get(|| async { file(STYLE, "text/css; charset=utf-8") }),
        )
        .route("/web/icon.png", get(|| async { file(ICON, "image/png") }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    #[tokio::test]
    async fn the_player_is_served_with_a_strict_policy() {
        let app: Router = routes();
        let response = app
            .clone()
            .oneshot(Request::get("/web/").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let policy = response.headers()[header::CONTENT_SECURITY_POLICY]
            .to_str()
            .unwrap();
        assert!(policy.contains("script-src 'self'") && !policy.contains("unsafe"));
        let root = app
            .oneshot(Request::get("/").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(root.headers()[header::LOCATION], "/web/");
    }

    #[test]
    fn the_page_loads_only_its_own_files() {
        for address in ["http://", "https://", "//"] {
            assert!(!INDEX.contains(address), "{address}");
        }
        assert!(
            !SCRIPT.contains("innerHTML"),
            "texts go through textContent"
        );
    }
}
