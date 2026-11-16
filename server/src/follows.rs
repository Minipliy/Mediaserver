//! Following artists: when one of them releases something new, the music
//! service loads it by itself.
//!
//! The list lives on the server, so every device and the web player share it.
//! A check looks at the artist's releases in the iTunes catalog every few hours;
//! anything released since the day of following that was not handed to the
//! music service before becomes a request. Without the music service set up
//! (see `music`), the list can still be kept but nothing is loaded.

use crate::{ApiError, AppState, catalog::now, music};
use axum::{Json, extract::State};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashSet, time::Duration};

const FIRST_CHECK: Duration = Duration::from_secs(120);
const CHECK_EVERY: Duration = Duration::from_secs(6 * 3600);
/// A catalog copy younger than this counts as current for the check.
const CATALOG_AGE: u64 = 5 * 3600;
/// Between two artists, to stay well inside Apple's request limit.
const ARTIST_PAUSE: Duration = Duration::from_secs(4);
const MAX_FOLLOWS: usize = 500;

/// GET /v1/music/follows
pub async fn list(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    let follows: Vec<Value> = state
        .store
        .follows()
        .await?
        .into_iter()
        .map(|(name, since)| json!({"name": name, "since": since}))
        .collect();
    Ok(Json(json!({
        "follows": follows,
        // Whether new releases are loaded, or only remembered.
        "loading": music::jobs_directory(&state).is_some(),
    })))
}

#[derive(Deserialize)]
pub struct Change {
    name: String,
    follow: bool,
}

/// POST /v1/music/follows `{name, follow}`; answers with the new list.
pub async fn change(
    State(state): State<AppState>,
    Json(change): Json<Change>,
) -> Result<Json<Value>, ApiError> {
    let name = change.name.trim().to_owned();
    if name.is_empty() || name.chars().count() > 120 || name.chars().any(char::is_control) {
        return Err(ApiError::bad_request("artist name missing or too long"));
    }
    if change.follow {
        let known = state.store.follows().await?;
        let already = known
            .iter()
            .any(|(other, _)| other.eq_ignore_ascii_case(&name));
        if !already && known.len() >= MAX_FOLLOWS {
            return Err(ApiError::bad_request("too many followed artists"));
        }
        state.store.follow(name.clone(), now()).await?;
        // A release from today should not wait for the next round.
        if !already && let Some(directory) = music::jobs_directory(&state) {
            let state = state.clone();
            tokio::spawn(async move {
                if let Some((stored, since)) = state.store.follows().await.ok().and_then(|all| {
                    all.into_iter()
                        .find(|(other, _)| other.eq_ignore_ascii_case(&name))
                }) {
                    check(&state, &directory, &stored, since).await;
                }
            });
        }
    } else {
        state.store.unfollow(name).await?;
    }
    list(State(state)).await
}

/// Looks for new releases now and then, while the music service is set up.
pub fn spawn(state: AppState) {
    tokio::spawn(async move {
        tokio::time::sleep(FIRST_CHECK).await;
        loop {
            if let Some(directory) = music::jobs_directory(&state)
                && let Ok(follows) = state.store.follows().await
            {
                for (name, since) in follows {
                    check(&state, &directory, &name, since).await;
                    tokio::time::sleep(ARTIST_PAUSE).await;
                }
            }
            tokio::time::sleep(CHECK_EVERY).await;
        }
    });
}

async fn check(state: &AppState, directory: &std::path::Path, name: &str, since: u64) {
    let Some((artist, releases)) = music::releases_of(state, name, CATALOG_AGE).await else {
        return;
    };
    let Ok(queued) = state.store.queued_releases().await else {
        return;
    };
    for release in new_releases(&releases, &day(since), &queued) {
        let (Some(id), Some(title)) = (
            release.get("id").and_then(Value::as_u64),
            release.get("title").and_then(Value::as_str),
        ) else {
            continue;
        };
        let job = music::NewJob {
            kind: "album".into(),
            item_id: id,
            title: title.to_owned(),
            artist: Some(artist.clone()),
            cover: release
                .get("cover")
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        let directory = directory.to_owned();
        let filed = tokio::task::spawn_blocking(move || music::write_job(&directory, job)).await;
        // Only what reached the service counts as handled; a full queue retries later.
        if matches!(filed, Ok(Ok(_))) {
            tracing::info!("new release of a followed artist requested");
            let _ = state
                .store
                .mark_release_queued(id, artist.clone(), title.to_owned())
                .await;
        }
    }
}

/// Releases from the day of following on that were not requested before.
/// Older ones are what the person already chose not to load.
pub fn new_releases<'a>(
    releases: &'a [Value],
    since_day: &str,
    queued: &HashSet<u64>,
) -> Vec<&'a Value> {
    releases
        .iter()
        .filter(|release| {
            release
                .get("released")
                .and_then(Value::as_str)
                .is_some_and(|released| released >= since_day)
                && release
                    .get("id")
                    .and_then(Value::as_u64)
                    .is_some_and(|id| !queued.contains(&id))
        })
        .collect()
}

/// "YYYY-MM-DD" (UTC) for Unix seconds, as the catalog writes release days.
pub fn day(seconds: u64) -> String {
    // Howard Hinnant's days-to-civil algorithm.
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days.div_euclid(146_097);
    let of_era = days.rem_euclid(146_097);
    let year_of_era = (of_era - of_era / 1460 + of_era / 36_524 - of_era / 146_096) / 365;
    let of_year = of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * of_year + 2) / 153;
    let day = of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_match_the_calendar() {
        assert_eq!(day(0), "1970-01-01");
        assert_eq!(day(951_782_400), "2000-02-29");
        assert_eq!(day(1_794_700_000), "2026-11-14");
        assert_eq!(day(1_798_761_599), "2026-12-31");
    }

    #[test]
    fn only_new_and_unrequested_releases_count() {
        let releases = vec![
            json!({"id": 1, "title": "Neu", "released": "2026-11-20"}),
            json!({"id": 2, "title": "Am selben Tag", "released": "2026-11-14"}),
            json!({"id": 3, "title": "Alt", "released": "2025-03-01"}),
            json!({"id": 4, "title": "Schon geladen", "released": "2026-11-15"}),
            json!({"id": 5, "title": "Ohne Datum"}),
        ];
        let queued = HashSet::from([4]);
        let ids: Vec<u64> = new_releases(&releases, "2026-11-14", &queued)
            .iter()
            .filter_map(|r| r["id"].as_u64())
            .collect();
        assert_eq!(ids, [1, 2]);
    }
}
