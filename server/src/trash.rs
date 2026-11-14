//! Deleting from the app. Files move to a hidden folder on the same disk and go
//! for good after two weeks, so that a slip or a stolen token cannot wipe the
//! library at once. Requires `MINIPLY_DELETES=1` and write access to the media.
//!
//! Only paths from the index are touched, never a path sent by a client.

use crate::{ApiError, AppState, catalog::Media};
use axum::{Json, extract::State, http::StatusCode};
use cap_std::fs::Dir;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeSet, HashMap},
    io,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const TRASH: &str = ".miniply-papierkorb";
const KEEP_SECONDS: u64 = 14 * 24 * 3600;
const PURGE_CHECK: Duration = Duration::from_secs(6 * 3600);
const MAX_IDS: usize = 5000;
pub const MAX_BODY: usize = 512 * 1024;
const SIDECARS: [&str; 4] = ["srt", "vtt", "lrc", "txt"];
const FOLDER_IMAGES: [&str; 6] = ["jpg", "jpeg", "png", "webp", "gif", "heic"];

pub fn enabled_by_environment() -> bool {
    matches!(
        std::env::var("MINIPLY_DELETES")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "1" | "true" | "on" | "yes"
    )
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |time| time.as_secs())
}

fn extension(name: &str) -> String {
    name.rsplit_once('.')
        .map_or_else(String::new, |(_, ext)| ext.to_ascii_lowercase())
}

fn split(path: &str) -> (&str, &str) {
    path.rsplit_once('/').unwrap_or(("", path))
}

/// Oldest modification time of every path in the trash: the first version of a
/// file that was replaced by a newer download.
pub fn earliest_copies(root: &std::path::Path) -> HashMap<String, u64> {
    fn walk(dir: &std::path::Path, relative: &str, found: &mut HashMap<String, u64>, depth: usize) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = if relative.is_empty() {
                name.clone()
            } else {
                format!("{relative}/{name}")
            };
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() && depth < 12 {
                walk(&entry.path(), &path, found, depth + 1);
            } else if kind.is_file()
                && let Some(modified) = entry
                    .metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            {
                let at = modified.as_secs();
                found
                    .entry(path)
                    .and_modify(|v| *v = (*v).min(at))
                    .or_insert(at);
            }
        }
    }
    let mut found = HashMap::new();
    let Ok(batches) = std::fs::read_dir(root.join(TRASH)) else {
        return found;
    };
    for batch in batches.flatten() {
        if batch.file_type().is_ok_and(|k| k.is_dir()) {
            walk(&batch.path(), "", &mut found, 0);
        }
    }
    found
}

fn to_trash(root: &Dir, batch: &str, path: &str) -> io::Result<()> {
    let target = format!("{TRASH}/{batch}/{path}");
    root.create_dir_all(split(&target).0)?;
    root.rename(path, root, &target)
}

/// Subtitles and lyrics that exist only for this file: "Film.de.srt" for "Film.mp4".
fn sidecars<'a>(media: &Media, files: &'a HashMap<String, Media>) -> Vec<&'a str> {
    let (folder, name) = split(&media.path);
    let Some((stem, _)) = name.rsplit_once('.') else {
        return Vec::new();
    };
    let prefix = format!("{stem}.");
    let shared = files.values().any(|other| {
        other.id != media.id
            && other.kind != "file"
            && split(&other.path).0 == folder
            && other.name.starts_with(&prefix)
    });
    if shared {
        return Vec::new();
    }
    files
        .values()
        .filter(|other| {
            other.kind == "file"
                && split(&other.path).0 == folder
                && other.name.starts_with(&prefix)
                && SIDECARS.contains(&extension(&other.name).as_str())
        })
        .map(|other| other.path.as_str())
        .collect()
}

/// Nothing is left that someone would miss: only covers and hidden files.
fn folder_is_finished(root: &Dir, folder: &str) -> io::Result<Option<Vec<String>>> {
    let mut leftovers = Vec::new();
    for entry in root.read_dir(folder)? {
        let entry = entry?;
        let Ok(name) = entry.file_name().into_string() else {
            return Ok(None);
        };
        let is_cover =
            entry.file_type()?.is_file() && FOLDER_IMAGES.contains(&extension(&name).as_str());
        if !name.starts_with('.') && !is_cover {
            return Ok(None);
        }
        leftovers.push(format!("{folder}/{name}"));
    }
    Ok(Some(leftovers))
}

/// Album, season and series folders go with their last file. "Musik" and the
/// other folders directly on the disk stay.
fn remove_finished_folders(root: &Dir, batch: &str, folder: &str) -> io::Result<()> {
    let mut folder = folder;
    while folder.contains('/') {
        let Some(leftovers) = folder_is_finished(root, folder)? else {
            break;
        };
        for path in leftovers {
            to_trash(root, batch, &path)?;
        }
        root.remove_dir(folder)?;
        folder = split(folder).0;
    }
    Ok(())
}

struct Doomed {
    id: String,
    path: String,
    sidecars: Vec<String>,
}

fn delete_files(root: &Dir, doomed: &[Doomed]) -> (usize, usize) {
    let batch = format!("{}-{}", now(), uuid::Uuid::new_v4());
    let (mut deleted, mut failed) = (0, 0);
    let mut folders = BTreeSet::new();
    for item in doomed {
        if let Err(error) = to_trash(root, &batch, &item.path) {
            tracing::warn!(kind = %error.kind(), "delete: cannot move a file to the trash");
            failed += 1;
            continue;
        }
        deleted += 1;
        for sidecar in &item.sidecars {
            let _ = to_trash(root, &batch, sidecar);
        }
        let (folder, name) = split(&item.path);
        let apple_double = if folder.is_empty() {
            format!("._{name}")
        } else {
            format!("{folder}/._{name}")
        };
        let _ = to_trash(root, &batch, &apple_double);
        folders.insert(folder.to_owned());
        // Copies made from the file: without it they only take up space.
        let _ = root.remove_dir_all(format!(".miniply-playback/{}", item.id));
        let _ = root.remove_dir_all(format!(".miniply-hls/{}", item.id));
    }
    for folder in folders.iter().rev() {
        if let Err(error) = remove_finished_folders(root, &batch, folder) {
            tracing::warn!(kind = %error.kind(), "delete: cannot clear an emptied folder");
        }
    }
    (deleted, failed)
}

#[derive(Deserialize)]
pub struct DeleteRequest {
    ids: Vec<String>,
}

pub async fn delete(
    State(state): State<AppState>,
    Json(request): Json<DeleteRequest>,
) -> Result<Json<Value>, ApiError> {
    if !state.deletes {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "deleting is disabled on this server (MINIPLY_DELETES)",
        ));
    }
    if request.ids.is_empty() || request.ids.len() > MAX_IDS {
        return Err(ApiError::bad_request("between 1 and 5000 ids are required"));
    }
    let doomed: Vec<Doomed> = {
        let catalog = state.catalog.read().await;
        request
            .ids
            .iter()
            .filter_map(|id| catalog.files.get(id))
            .filter(|media| media.kind == "audio" || media.kind == "video")
            .map(|media| Doomed {
                id: media.id.clone(),
                path: media.path.clone(),
                sidecars: sidecars(media, &catalog.files)
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
            })
            .collect()
    };
    let root = state.root.clone();
    let (deleted, failed) = tokio::task::spawn_blocking(move || delete_files(&root, &doomed))
        .await
        .map_err(|_| ApiError::internal())?;
    state.rescan().await?;
    Ok(Json(json!({ "deleted": deleted, "failed": failed })))
}

fn purge(root: &Dir, now: u64) -> io::Result<()> {
    let batches = match root.read_dir(TRASH) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        other => other?,
    };
    for batch in batches {
        let Ok(name) = batch?.file_name().into_string() else {
            continue;
        };
        let moved = name
            .split('-')
            .next()
            .and_then(|time| time.parse::<u64>().ok());
        if moved.is_some_and(|moved| now.saturating_sub(moved) > KEEP_SECONDS) {
            root.remove_dir_all(format!("{TRASH}/{name}"))?;
        }
    }
    Ok(())
}

pub fn spawn(state: AppState) {
    if !state.deletes {
        return;
    }
    tokio::spawn(async move {
        loop {
            let root = state.root.clone();
            let result = tokio::task::spawn_blocking(move || purge(&root, now())).await;
            if !matches!(result, Ok(Ok(()))) {
                tracing::warn!("cannot empty old batches of the trash");
            }
            tokio::time::sleep(PURGE_CHECK).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_old_batches_are_purged() {
        let temp = tempfile::tempdir().unwrap();
        let root = Dir::open_ambient_dir(temp.path(), cap_std::ambient_authority()).unwrap();
        root.create_dir_all(format!("{TRASH}/100-old/Musik"))
            .unwrap();
        root.create_dir_all(format!("{TRASH}/2000000-new/Musik"))
            .unwrap();
        root.create_dir_all(format!("{TRASH}/unknown/Musik"))
            .unwrap();
        purge(&root, 100 + KEEP_SECONDS + 1).unwrap();
        assert!(!root.exists(format!("{TRASH}/100-old")));
        assert!(root.exists(format!("{TRASH}/2000000-new")));
        assert!(root.exists(format!("{TRASH}/unknown")));
    }
}
