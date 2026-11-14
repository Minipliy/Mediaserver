//! Still images for videos without their own poster, made once with FFmpeg
//! and kept in SQLite (`artwork` table, ID `thumb-<media id>`).
//!
//! Needs `ffmpeg` on the server. Disable with `MINIPLY_THUMBNAILS=0`.

use crate::AppState;
use std::{process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command};

const MAX_IMAGE: usize = 4 * 1024 * 1024;

pub fn enabled() -> bool {
    !matches!(
        std::env::var("MINIPLY_THUMBNAILS")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

pub fn artwork_id(media_id: &str) -> String {
    format!("thumb-{media_id}")
}

async fn ffmpeg_available() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

/// One JPEG frame at `at` seconds, at most 640 px wide.
async fn frame(path: &std::path::Path, at: u32) -> Option<Vec<u8>> {
    let mut child = Command::new("ffmpeg")
        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-ss"])
        .arg(at.to_string())
        .arg("-i")
        .arg(path)
        .args([
            "-frames:v",
            "1",
            "-an",
            "-sn",
            "-vf",
            "scale='min(640,iw)':-2",
            "-q:v",
            "4",
            "-f",
            "image2pipe",
            "-vcodec",
            "mjpeg",
            "pipe:1",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let read = async {
        let mut data = Vec::new();
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let n = stdout.read(&mut buffer).await.ok()?;
            if n == 0 {
                break;
            }
            data.extend_from_slice(&buffer[..n]);
            if data.len() > MAX_IMAGE {
                return None;
            }
        }
        Some(data)
    };
    let data = tokio::time::timeout(Duration::from_secs(90), read)
        .await
        .ok()??;
    let status = tokio::time::timeout(Duration::from_secs(10), child.wait())
        .await
        .ok()?
        .ok()?;
    (status.success() && data.starts_with(&[0xFF, 0xD8])).then_some(data)
}

/// Background worker: after each scan, create missing stills one by one.
pub fn spawn(state: AppState) {
    if !enabled() {
        tracing::info!("video thumbnails disabled (MINIPLY_THUMBNAILS=0)");
        return;
    }
    tokio::spawn(async move {
        if !ffmpeg_available().await {
            tracing::info!("video thumbnails: ffmpeg not installed, skipping");
            return;
        }
        tokio::time::sleep(Duration::from_secs(8)).await;
        let mut failed = std::collections::HashSet::new();
        loop {
            let todo: Vec<(String, String)> = {
                let catalog = state.catalog.read().await;
                let done = state.thumbnails.read().await;
                let mut list: Vec<_> = catalog
                    .files
                    .values()
                    .filter(|m| {
                        m.kind == "video" && !done.contains(&m.id) && !failed.contains(&m.id)
                    })
                    .map(|m| (m.id.clone(), m.path.clone()))
                    .collect();
                list.sort_by(|a, b| a.1.cmp(&b.1));
                list
            };
            if !todo.is_empty() {
                tracing::info!(count = todo.len(), "video thumbnails: creating stills");
            }
            for (id, relative) in todo {
                // Resolve inside the media root; never follow a path that
                // leaves it (symlinks are not indexed, this re-checks).
                let Ok(path) = state.root_path.join(&relative).canonicalize() else {
                    failed.insert(id);
                    continue;
                };
                if !path.starts_with(&state.root_path) {
                    failed.insert(id);
                    continue;
                }
                let mut image = None;
                for at in [90, 20, 3, 0] {
                    if let Some(data) = frame(&path, at).await {
                        image = Some(data);
                        break;
                    }
                }
                match image {
                    Some(data) => {
                        if state
                            .store
                            .save_artwork(artwork_id(&id), "image/jpeg".into(), data)
                            .await
                            .is_ok()
                        {
                            state.thumbnails.write().await.insert(id);
                        }
                    }
                    None => {
                        failed.insert(id);
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(120)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn still_from_a_generated_video() {
        if !super::ffmpeg_available().await {
            return; // FFmpeg is optional on development machines.
        }
        let temp = tempfile::tempdir().unwrap();
        let video = temp.path().join("clip.mp4");
        let made = tokio::process::Command::new("ffmpeg")
            .args([
                "-nostdin",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc=size=320x240:rate=10",
                "-t",
                "5",
            ])
            .arg(&video)
            .status()
            .await
            .unwrap();
        assert!(made.success());
        // 90 s is past the end; the worker then tries earlier positions.
        assert!(super::frame(&video, 90).await.is_none());
        let image = super::frame(&video, 3).await.expect("jpeg still");
        assert!(image.starts_with(&[0xFF, 0xD8]));
    }
}
