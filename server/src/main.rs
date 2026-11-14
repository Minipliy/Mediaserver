use miniply_server::{AppState, router};
use std::{env, path::PathBuf, time::Duration};

#[tokio::main(worker_threads = 2)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "miniply_server=info".into()),
        )
        .init();
    let root =
        PathBuf::from(env::var("MINIPLY_MEDIA_ROOT").unwrap_or_else(|_| "/srv/media".into()));
    let token = env::var("MINIPLY_TOKEN")
        .map_err(|_| "set MINIPLY_TOKEN to a randomly generated secret (at least 32 characters)")?;
    let database =
        PathBuf::from(env::var("MINIPLY_DATABASE").unwrap_or_else(|_| "./miniply.sqlite".into()));
    let bind = env::var("MINIPLY_BIND").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let interval = env::var("MINIPLY_SCAN_SECONDS")
        .unwrap_or_else(|_| "60".into())
        .parse::<u64>()?
        .clamp(15, 86_400);
    let state = AppState::new(root, &token, database).await?;
    miniply_server::metadata::spawn(state.clone());
    miniply_server::extras::spawn_lyrics(state.clone());
    miniply_server::thumbnails::spawn(state.clone());
    miniply_server::analysis::spawn(state.clone());
    miniply_server::music::spawn(state.clone());
    miniply_server::music_catalog::spawn(state.clone());
    state.spawn_trash_cleanup();
    let scanner = state.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(interval)).await;
            if scanner.rescan().await.is_err() {
                tracing::error!("library rescan failed");
            }
        }
    });
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(address = %bind, "Miniply ready (no request URLs or credentials are logged)");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

async fn shutdown() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
}
