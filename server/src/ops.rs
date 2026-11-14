//! Operation: the state of the Pi for the app's status page, and crash reports
//! the app collects with MetricKit and hands to its own server (no third party).

use crate::{ApiError, AppState};
use axum::{Json, body::Bytes, extract::State, http::StatusCode};
use std::{path::Path, time::SystemTime};

/// MetricKit reports are JSON of a few dozen kilobytes; more is not a report.
pub const MAX_REPORT: usize = 1024 * 1024;
/// Only the newest reports are kept.
const KEEP_REPORTS: usize = 50;

fn read(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

/// "MemAvailable:  356000 kB" -> bytes.
fn meminfo(text: &str, key: &str) -> Option<u64> {
    let line = text.lines().find(|l| l.starts_with(key))?;
    let kilobytes: u64 = line[key.len()..]
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse()
        .ok()?;
    Some(kilobytes * 1024)
}

fn age_seconds(path: &Path) -> Option<u64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    SystemTime::now()
        .duration_since(modified)
        .ok()
        .map(|d| d.as_secs())
}

pub async fn status(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let root = state.root_path.clone();
    let jobs = state.music_jobs.clone();
    let system = tokio::task::spawn_blocking(move || {
        let memory = read("/proc/meminfo").unwrap_or_default();
        serde_json::json!({
            "uptime_seconds": read("/proc/uptime")
                .and_then(|t| t.split_whitespace().next()?.parse::<f64>().ok())
                .map(|s| s as u64),
            "load": read("/proc/loadavg")
                .and_then(|t| t.split_whitespace().next()?.parse::<f64>().ok()),
            "memory_total_bytes": meminfo(&memory, "MemTotal:"),
            "memory_available_bytes": meminfo(&memory, "MemAvailable:"),
            "temperature_c": read("/sys/class/thermal/thermal_zone0/temp")
                .and_then(|t| t.trim().parse::<f64>().ok())
                .map(|milli| (milli / 100.0).round() / 10.0),
            "disk_total_bytes": fs2::total_space(&root).ok(),
            "disk_available_bytes": fs2::available_space(&root).ok(),
            "music_service_seconds_ago": age_seconds(&jobs.join("heartbeat")),
        })
    })
    .await
    .map_err(|_| ApiError::internal())?;
    let (songs, levelled, seasons_with_intro) = {
        let catalog = state.catalog.read().await;
        let songs = catalog.files.values().filter(|m| m.kind == "audio").count();
        let levelled = catalog
            .files
            .values()
            .filter(|m| m.kind == "audio" && m.gain_db.is_some())
            .count();
        let mut seasons = std::collections::HashSet::new();
        for media in catalog.files.values().filter(|m| m.intro.is_some()) {
            seasons.insert((media.series_key.clone(), media.season));
        }
        (songs, levelled, seasons.len())
    };
    let scanned_at = state.catalog.read().await.scanned_at;
    let mut answer = system;
    answer["scanned_at"] = serde_json::json!(scanned_at);
    answer["songs"] = serde_json::json!(songs);
    answer["songs_levelled"] = serde_json::json!(levelled);
    answer["seasons_with_intro"] = serde_json::json!(seasons_with_intro);
    answer["music_catalog"] = serde_json::json!(crate::music_catalog::status(&state).await);
    Ok(Json(answer))
}

/// Stores one crash or hang report from the app for later reading on the Pi.
pub async fn diagnostics(
    State(state): State<AppState>,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    if body.is_empty()
        || body.len() > MAX_REPORT
        || serde_json::from_slice::<serde_json::Value>(&body).is_err()
    {
        return Err(ApiError::bad_request("expected a JSON report"));
    }
    let folder = state.music_jobs.with_file_name("diagnostics");
    tokio::task::spawn_blocking(move || -> std::io::Result<()> {
        std::fs::create_dir_all(&folder)?;
        let stamp = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let name = format!("{stamp}-{}.json", uuid::Uuid::new_v4());
        let temporary = folder.join(format!(".{name}"));
        std::fs::write(&temporary, &body)?;
        std::fs::rename(&temporary, folder.join(&name))?;
        let mut reports: Vec<_> = std::fs::read_dir(&folder)?
            .filter_map(Result::ok)
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".json") && !n.starts_with('.'))
            .collect();
        reports.sort();
        let excess = reports.len().saturating_sub(KEEP_REPORTS);
        for old in &reports[..excess] {
            let _ = std::fs::remove_file(folder.join(old));
        }
        Ok(())
    })
    .await
    .map_err(|_| ApiError::internal())?
    .map_err(|_| ApiError::internal())?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize, serde::Serialize)]
pub struct PushDevice {
    token: String,
    environment: String,
}

fn valid_device(device: &PushDevice) -> bool {
    (32..=200).contains(&device.token.len())
        && device.token.bytes().all(|b| b.is_ascii_hexdigit())
        && matches!(device.environment.as_str(), "production" | "sandbox")
}

/// The app registers its push address so the outage watchers can warn this iPhone.
pub async fn register_device(
    State(state): State<AppState>,
    Json(device): Json<PushDevice>,
) -> Result<StatusCode, ApiError> {
    if !valid_device(&device) {
        return Err(ApiError::bad_request(
            "expected a hex push token and environment production or sandbox",
        ));
    }
    state
        .store
        .save_push_device(
            device.token.to_ascii_lowercase(),
            device.environment,
            crate::catalog::now(),
        )
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// For the outage watchers on the Pi and the VPS, which keep a copy for when the Pi is down.
pub async fn devices(State(state): State<AppState>) -> Result<Json<Vec<PushDevice>>, ApiError> {
    let devices = state.store.push_devices().await?;
    Ok(Json(
        devices
            .into_iter()
            .map(|(token, environment)| PushDevice { token, environment })
            .collect(),
    ))
}

#[cfg(test)]
mod tests {
    #[test]
    fn push_devices() {
        let device = |token: &str, environment: &str| super::PushDevice {
            token: token.into(),
            environment: environment.into(),
        };
        assert!(super::valid_device(&device(&"ab".repeat(32), "production")));
        assert!(super::valid_device(&device(&"AB".repeat(32), "sandbox")));
        assert!(!super::valid_device(&device(&"ab".repeat(32), "test")));
        assert!(!super::valid_device(&device("abc", "production")));
        assert!(!super::valid_device(&device(
            &"zz".repeat(32),
            "production"
        )));
    }

    #[test]
    fn memory_lines() {
        let text = "MemTotal:        8000 kB\nMemAvailable:    2000 kB\n";
        assert_eq!(super::meminfo(text, "MemAvailable:"), Some(2000 * 1024));
        assert_eq!(super::meminfo(text, "SwapTotal:"), None);
    }
}
