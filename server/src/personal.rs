//! Favourites, watched state and play statistics shared between devices.
//!
//! Devices send what changed and receive what changed since their last sync,
//! so a device that was offline for a while simply catches up. Flags keep the
//! latest change including removals, play counts are summed per device and
//! the last play time is the newest one.

use crate::{ApiError, AppState, catalog::now};
use axum::{Json, extract::State, http::StatusCode};
use rusqlite::params;
use serde::{Deserialize, Serialize};

pub const MAX_BODY: usize = 16 * 1024 * 1024;

#[derive(Serialize, Deserialize, Clone)]
pub struct Flag {
    pub id: String,
    pub on: bool,
    pub at: f64,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct PlayCount {
    pub id: String,
    pub count: u64,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct LastPlayed {
    pub id: String,
    pub at: f64,
}

#[derive(Deserialize)]
pub struct SyncRequest {
    device: String,
    /// The `cursor` of the previous answer; 0 asks for everything.
    #[serde(default)]
    since: i64,
    #[serde(default)]
    favorites: Vec<Flag>,
    #[serde(default)]
    watched: Vec<Flag>,
    #[serde(default)]
    plays: Vec<PlayCount>,
    #[serde(default)]
    last_played: Vec<LastPlayed>,
}

#[derive(Serialize, Default)]
pub struct SyncResponse {
    /// Pass this back as `since`. Lower than `since` means the server lost
    /// state (a restored backup): the device then sends everything again.
    cursor: i64,
    favorites: Vec<Flag>,
    watched: Vec<Flag>,
    /// Sum over all devices, including this one.
    plays: Vec<PlayCount>,
    last_played: Vec<LastPlayed>,
}

fn valid_device(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn valid_media(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A wrong clock must not win against every later change forever.
fn valid_time(value: f64, latest: f64) -> Option<f64> {
    (value.is_finite() && value >= 0.0).then(|| value.min(latest))
}

/// POST /v1/personal/sync
pub async fn sync(
    State(state): State<AppState>,
    Json(request): Json<SyncRequest>,
) -> Result<Json<SyncResponse>, ApiError> {
    if !valid_device(&request.device) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid device"));
    }
    let ids_valid = request
        .favorites
        .iter()
        .chain(&request.watched)
        .all(|f| valid_media(&f.id))
        && request.plays.iter().all(|p| valid_media(&p.id))
        && request.last_played.iter().all(|p| valid_media(&p.id));
    if !ids_valid {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid media ID"));
    }
    let latest = (now() + 86_400) as f64;
    let since = request.since.max(0);
    let response = state
        .store
        .run(move |db| {
            let transaction = db.unchecked_transaction()?;
            transaction.execute(
                "INSERT INTO personal_revision (id, revision) VALUES (1, 1)
                 ON CONFLICT (id) DO UPDATE SET revision = revision + 1",
                [],
            )?;
            let revision: i64 = transaction.query_row(
                "SELECT revision FROM personal_revision WHERE id = 1",
                [],
                |row| row.get(0),
            )?;
            {
                let mut flag = transaction.prepare(
                    "INSERT INTO personal_flags (kind, media_id, enabled, changed_at, revision) VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT (kind, media_id) DO UPDATE SET enabled = excluded.enabled, changed_at = excluded.changed_at, revision = excluded.revision
                     WHERE excluded.changed_at > changed_at OR (excluded.changed_at = changed_at AND excluded.enabled > enabled)",
                )?;
                for (kind, list) in [
                    ("favorite", &request.favorites),
                    ("watched", &request.watched),
                ] {
                    for item in list {
                        let Some(at) = valid_time(item.at, latest) else {
                            continue;
                        };
                        flag.execute(params![kind, item.id, item.on, at, revision])?;
                    }
                }
                let mut plays = transaction.prepare(
                    "INSERT INTO personal_plays (device, media_id, count, revision) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT (device, media_id) DO UPDATE SET count = excluded.count, revision = excluded.revision
                     WHERE excluded.count > count",
                )?;
                for item in &request.plays {
                    plays.execute(params![
                        request.device,
                        item.id,
                        item.count.min(i64::MAX as u64) as i64,
                        revision
                    ])?;
                }
                let mut played = transaction.prepare(
                    "INSERT INTO personal_last_played (media_id, played_at, revision) VALUES (?1, ?2, ?3)
                     ON CONFLICT (media_id) DO UPDATE SET played_at = excluded.played_at, revision = excluded.revision
                     WHERE excluded.played_at > played_at",
                )?;
                for item in &request.last_played {
                    let Some(at) = valid_time(item.at, latest) else {
                        continue;
                    };
                    played.execute(params![item.id, at, revision])?;
                }
            }
            transaction.commit()?;
            let flags = |kind: &str| -> rusqlite::Result<Vec<Flag>> {
                db.prepare(
                    "SELECT media_id, enabled, changed_at FROM personal_flags WHERE kind = ?1 AND revision > ?2",
                )?
                .query_map(params![kind, since], |row| {
                    Ok(Flag {
                        id: row.get(0)?,
                        on: row.get(1)?,
                        at: row.get(2)?,
                    })
                })?
                .collect()
            };
            Ok(SyncResponse {
                cursor: revision,
                favorites: flags("favorite")?,
                watched: flags("watched")?,
                plays: db
                    .prepare(
                        "SELECT media_id, sum(count) FROM personal_plays GROUP BY media_id HAVING max(revision) > ?1",
                    )?
                    .query_map([since], |row| {
                        Ok(PlayCount {
                            id: row.get(0)?,
                            count: row.get::<_, i64>(1)?.max(0) as u64,
                        })
                    })?
                    .collect::<rusqlite::Result<_>>()?,
                last_played: db
                    .prepare("SELECT media_id, played_at FROM personal_last_played WHERE revision > ?1")?
                    .query_map([since], |row| {
                        Ok(LastPlayed {
                            id: row.get(0)?,
                            at: row.get(1)?,
                        })
                    })?
                    .collect::<rusqlite::Result<_>>()?,
            })
        })
        .await?;
    Ok(Json(response))
}
