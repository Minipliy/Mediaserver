use crate::{ApiError, catalog::now, metadata::Entry};
use rusqlite::OptionalExtension;
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::Path,
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub struct Store(Arc<Mutex<Connection>>);

#[derive(Serialize, Deserialize)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub media_ids: Vec<String>,
}

#[derive(Serialize, Deserialize, Default)]
pub struct Progress {
    pub seconds: f64,
    #[serde(default)]
    pub updated_at: u64,
}

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let db = Connection::open(path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS playlists (id TEXT PRIMARY KEY, name TEXT NOT NULL, media_ids TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS progress (media_id TEXT PRIMARY KEY, seconds REAL NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, entry TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS artwork (id TEXT PRIMARY KEY, content_type TEXT NOT NULL, data BLOB NOT NULL, fetched_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS personal_flags (kind TEXT NOT NULL, media_id TEXT NOT NULL, enabled INTEGER NOT NULL, changed_at REAL NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY (kind, media_id));
            CREATE TABLE IF NOT EXISTS personal_plays (device TEXT NOT NULL, media_id TEXT NOT NULL, count INTEGER NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY (device, media_id));
            CREATE TABLE IF NOT EXISTS personal_last_played (media_id TEXT PRIMARY KEY, played_at REAL NOT NULL, revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS personal_revision (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS loudness (media_id TEXT PRIMARY KEY, modified INTEGER NOT NULL, gain_db REAL);
            CREATE TABLE IF NOT EXISTS intros (media_id TEXT PRIMARY KEY, modified INTEGER NOT NULL, start REAL, end REAL);
            CREATE TABLE IF NOT EXISTS first_seen (media_id TEXT PRIMARY KEY, at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS push_devices (token TEXT PRIMARY KEY, environment TEXT NOT NULL, seen INTEGER NOT NULL);")?;
        Ok(Self(Arc::new(Mutex::new(db))))
    }

    pub async fn run<T: Send + 'static>(
        &self,
        action: impl FnOnce(&Connection) -> rusqlite::Result<T> + Send + 'static,
    ) -> Result<T, ApiError> {
        let this = self.clone();
        tokio::task::spawn_blocking(move || {
            let guard = this.0.lock().map_err(|_| ApiError::internal())?;
            action(&guard).map_err(|e| {
                tracing::error!("database: {e}");
                ApiError::internal()
            })
        })
        .await
        .map_err(|_| ApiError::internal())?
    }

    pub async fn playlists(&self) -> Result<Vec<Playlist>, ApiError> {
        self.run(|db| {
            let mut stmt =
                db.prepare("SELECT id, name, media_ids FROM playlists ORDER BY name, id")?;
            stmt.query_map([], |row| {
                let raw: String = row.get(2)?;
                Ok(Playlist {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    media_ids: serde_json::from_str(&raw).unwrap_or_default(),
                })
            })?
            .collect()
        })
        .await
    }

    pub async fn save_playlist(
        &self,
        playlist: Playlist,
        create: bool,
    ) -> Result<Playlist, ApiError> {
        self.run(move |db| {
            let items = serde_json::to_string(&playlist.media_ids).expect("string list");
            let changed = if create {
                db.execute(
                    "INSERT INTO playlists VALUES (?1, ?2, ?3)",
                    params![playlist.id, playlist.name, items],
                )?
            } else {
                db.execute(
                    "UPDATE playlists SET name=?2, media_ids=?3 WHERE id=?1",
                    params![playlist.id, playlist.name, items],
                )?
            };
            Ok((changed, playlist))
        })
        .await
        .and_then(|(changed, p)| {
            if changed == 0 {
                Err(ApiError::not_found())
            } else {
                Ok(p)
            }
        })
    }

    pub async fn delete_playlist(&self, id: String) -> Result<(), ApiError> {
        let changed = self
            .run(move |db| db.execute("DELETE FROM playlists WHERE id=?1", [id]))
            .await?;
        if changed == 0 {
            Err(ApiError::not_found())
        } else {
            Ok(())
        }
    }

    pub async fn progress(&self, id: String) -> Result<Progress, ApiError> {
        self.run(move |db| {
            db.query_row(
                "SELECT seconds, updated_at FROM progress WHERE media_id=?1",
                [id],
                |row| {
                    Ok(Progress {
                        seconds: row.get(0)?,
                        updated_at: row.get::<_, i64>(1)? as u64,
                    })
                },
            )
            .optional()
            .map(|p| p.unwrap_or_default())
        })
        .await
    }

    pub async fn save_progress(&self, id: String, seconds: f64) -> Result<(), ApiError> {
        self.run(move |db| db.execute("INSERT INTO progress VALUES (?1, ?2, ?3) ON CONFLICT(media_id) DO UPDATE SET seconds=excluded.seconds, updated_at=excluded.updated_at", params![id, seconds, now() as i64]).map(|_| ())).await
    }

    pub async fn load_metadata(&self) -> Result<HashMap<String, Entry>, ApiError> {
        self.run(|db| {
            let mut stmt = db.prepare("SELECT key, entry FROM metadata")?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            let mut result = HashMap::new();
            for row in rows {
                let (key, raw) = row?;
                if let Ok(entry) = serde_json::from_str::<Entry>(&raw) {
                    result.insert(key, entry);
                }
            }
            Ok(result)
        })
        .await
    }

    pub async fn save_metadata(&self, key: String, entry: Entry) -> Result<(), ApiError> {
        let raw = serde_json::to_string(&entry).map_err(|_| ApiError::internal())?;
        self.run(move |db| {
            db.execute(
                "INSERT INTO metadata VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET entry=excluded.entry",
                params![key, raw],
            )
            .map(|_| ())
        })
        .await
    }

    /// Earlier loudness and intro results (NULL: measured, nothing found).
    pub async fn load_analysis(&self) -> Result<crate::analysis::Analysis, ApiError> {
        self.run(|db| {
            let mut result = crate::analysis::Analysis::default();
            let mut stmt = db.prepare("SELECT media_id, modified, gain_db FROM loudness")?;
            for row in stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, Option<f64>>(2)?,
                ))
            })? {
                let (id, modified, gain) = row?;
                result
                    .loudness
                    .insert(id, (modified as u64, gain.map(|g| g as f32)));
            }
            let mut stmt = db.prepare("SELECT media_id, modified, start, end FROM intros")?;
            for row in stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, Option<f64>>(2)?,
                    r.get::<_, Option<f64>>(3)?,
                ))
            })? {
                let (id, modified, start, end) = row?;
                let intro = start
                    .zip(end)
                    .map(|(start, end)| crate::analysis::Intro { start, end });
                result.intros.insert(id, (modified as u64, intro));
            }
            Ok(result)
        })
        .await
    }

    pub async fn first_seen(&self) -> Result<HashMap<String, u64>, ApiError> {
        self.run(|db| {
            let mut stmt = db.prepare("SELECT media_id, at FROM first_seen")?;
            stmt.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))
            })?
            .collect()
        })
        .await
    }

    pub async fn save_first_seen(&self, rows: Vec<(String, u64)>) -> Result<(), ApiError> {
        self.run(move |db| {
            let transaction = db.unchecked_transaction()?;
            {
                let mut stmt = transaction
                    .prepare("INSERT OR IGNORE INTO first_seen (media_id, at) VALUES (?1, ?2)")?;
                for (id, at) in &rows {
                    stmt.execute(params![id, *at as i64])?;
                }
            }
            transaction.commit()
        })
        .await
    }

    /// Remembers an iPhone that wants outage warnings; tokens unseen for 90 days are dropped.
    pub async fn save_push_device(
        &self,
        token: String,
        environment: String,
        seen: u64,
    ) -> Result<(), ApiError> {
        self.run(move |db| {
            db.execute(
                "INSERT INTO push_devices (token, environment, seen) VALUES (?1, ?2, ?3)
                 ON CONFLICT(token) DO UPDATE SET environment = ?2, seen = ?3",
                params![token, environment, seen as i64],
            )?;
            db.execute(
                "DELETE FROM push_devices WHERE seen < ?1",
                params![seen.saturating_sub(90 * 86_400) as i64],
            )?;
            Ok(())
        })
        .await
    }

    pub async fn push_devices(&self) -> Result<Vec<(String, String)>, ApiError> {
        self.run(|db| {
            let mut stmt =
                db.prepare("SELECT token, environment FROM push_devices ORDER BY seen DESC")?;
            let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect()
        })
        .await
    }

    pub async fn save_loudness(
        &self,
        id: String,
        modified: u64,
        gain: Option<f32>,
    ) -> Result<(), ApiError> {
        self.run(move |db| {
            db.execute(
                "INSERT OR REPLACE INTO loudness (media_id, modified, gain_db) VALUES (?1, ?2, ?3)",
                params![id, modified as i64, gain.map(f64::from)],
            )
            .map(|_| ())
        })
        .await
    }

    pub async fn save_intro(
        &self,
        id: String,
        modified: u64,
        intro: Option<crate::analysis::Intro>,
    ) -> Result<(), ApiError> {
        self.run(move |db| {
            db.execute(
                "INSERT OR REPLACE INTO intros (media_id, modified, start, end) VALUES (?1, ?2, ?3, ?4)",
                params![id, modified as i64, intro.map(|i| i.start), intro.map(|i| i.end)],
            )
            .map(|_| ())
        })
        .await
    }

    /// Media IDs that already have a generated video still.
    pub async fn thumbnail_ids(&self) -> Result<std::collections::HashSet<String>, ApiError> {
        self.run(|db| {
            let mut stmt = db.prepare("SELECT id FROM artwork WHERE id LIKE 'thumb-%'")?;
            let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
            let mut result = std::collections::HashSet::new();
            for id in rows {
                if let Some(media) = id?.strip_prefix("thumb-") {
                    result.insert(media.to_owned());
                }
            }
            Ok(result)
        })
        .await
    }

    pub async fn has_artwork(&self, id: String) -> Result<bool, ApiError> {
        self.run(move |db| {
            db.query_row("SELECT 1 FROM artwork WHERE id=?1", [id], |_| Ok(()))
                .optional()
                .map(|row| row.is_some())
        })
        .await
    }

    pub async fn save_artwork(
        &self,
        id: String,
        content_type: String,
        data: Vec<u8>,
    ) -> Result<(), ApiError> {
        self.run(move |db| {
            db.execute(
                "INSERT OR REPLACE INTO artwork VALUES (?1, ?2, ?3, ?4)",
                params![id, content_type, data, now() as i64],
            )
            .map(|_| ())
        })
        .await
    }

    pub async fn artwork(&self, id: String) -> Result<Option<(String, Vec<u8>)>, ApiError> {
        self.run(move |db| {
            db.query_row(
                "SELECT content_type, data FROM artwork WHERE id=?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
        })
        .await
    }
}
