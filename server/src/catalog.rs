use cap_std::fs::Dir;
use lofty::prelude::*;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{collections::HashMap, path::Path, time::UNIX_EPOCH};

#[derive(Clone, Serialize)]
pub struct PlaybackVariant {
    pub file_extension: String,
    pub bytes: u64,
}

#[derive(Clone, Serialize)]
pub struct Media {
    pub id: String,
    pub path: String,
    pub name: String,
    pub kind: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration: Option<f64>,
    pub bytes: u64,
    pub modified: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playback: Option<PlaybackVariant>,
    /// An adaptive copy exists; the ticket then also names its playlist.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hls: bool,
    /// Music folder that forms this track's album (relative directory path).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub track_number: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disc_number: Option<u32>,
    /// Artwork ID for `/v1/artwork/{id}`: a folder image or embedded cover.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_id: Option<String>,
    /// Series folder path such as `Serien/Two and a Half Men`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_key: Option<String>,
    /// Season folder name below the series folder, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_folder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    /// Subtitle files next to a video (`Film.srt`, `Film.de.srt`, ...).
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub subtitles: Vec<SubtitleRef>,
    /// An `.lrc`/`.txt` file or embedded lyrics exist for this track.
    #[serde(skip_serializing_if = "std::ops::Not::not", default)]
    pub has_lyrics: bool,
    #[serde(skip)]
    pub embedded_lyrics: bool,
    /// Guest artists from "feat."/"ft." in the artist tag or title.
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub featured: Vec<String>,
    /// Full credit for display, e.g. "Eminem feat. Rihanna".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist_credit: Option<String>,
    #[serde(skip)]
    pub tag_title: Option<String>,
    #[serde(skip)]
    pub file_title: String,
    /// ReplayGain track gain in dB (for volume levelling in the app), from the tags
    /// or measured by the server.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gain_db: Option<f32>,
    /// Intro of a series episode that is the same in every episode of its season.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intro: Option<crate::analysis::Intro>,
    /// When the file first appeared (Unix seconds). A song replaced under the same name
    /// keeps the date of the first version, so "new" means new music.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub added: Option<u64>,
    /// The music finder could only find a censored version of this song.
    #[serde(skip_serializing_if = "std::ops::Not::not", default)]
    pub censored: bool,
    #[serde(skip)]
    pub playback_path: Option<String>,
    #[serde(skip)]
    pub modified_nanos: u128,
    #[serde(skip)]
    pub tag_artist: Option<String>,
    #[serde(skip)]
    pub tag_album: Option<String>,
    #[serde(skip)]
    pub embedded_art: bool,
}

#[derive(Clone, Serialize)]
pub struct SubtitleRef {
    /// Media ID of the subtitle file, for `/v1/subtitles/{id}`.
    pub id: String,
    /// ISO-like language code from the file name (`de`, `en`), if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    pub label: String,
    pub forced: bool,
}

#[derive(Default)]
pub struct Catalog {
    pub files: HashMap<String, Media>,
    pub directories: Vec<String>,
    /// Best cover image per directory (directory path -> artwork ID).
    pub covers: HashMap<String, String>,
    pub scanned_at: u64,
    pub scan_errors: usize,
    /// First few entries that could not be read, for the server log.
    pub skipped: Vec<String>,
}

fn skip(result: &mut Catalog, path: &str, reason: &str) {
    result.scan_errors += 1;
    if result.skipped.len() < 20 {
        result.skipped.push(format!("{path} ({reason})"));
    }
}

pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// "-7.89 dB" -> -7.89, limited to a plausible range.
pub fn parse_gain(value: &str) -> Option<f32> {
    let number = value
        .trim()
        .trim_end_matches(|c: char| c.is_alphabetic() || c == ' ');
    let gain: f32 = number.trim().replace(',', ".").parse().ok()?;
    (gain.is_finite() && (-30.0..=20.0).contains(&gain)).then_some(gain)
}

fn refresh_playback(root: &Dir, media: &mut Media) {
    let prepared = crate::playback::open(root, media, media.bytes, media.modified_nanos);
    media.playback = prepared.as_ref().map(|prepared| prepared.variant.clone());
    media.playback_path = prepared.map(|prepared| prepared.path);
    media.hls = crate::hls::available(root, media);
}

/// All traversal and file reads stay relative to this capability directory.
/// Symlinks, hidden files and special files are excluded from the index.
/// The length of an MP4, MOV or M4V video from its header, without decoding.
/// The app and the web player show it before an episode was ever played.
fn video_duration(root: &Dir, path: &str) -> Option<f64> {
    let extension = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    if !matches!(extension.as_str(), "mp4" | "m4v" | "mov") {
        return None;
    }
    let file = crate::file_access::open_regular(root, path).ok()?;
    let tagged = lofty::probe::Probe::new(file)
        .guess_file_type()
        .ok()?
        .options(lofty::config::ParseOptions::new().read_cover_art(false))
        .read()
        .ok()?;
    let seconds = tagged.properties().duration().as_secs_f64();
    (seconds > 0.0).then_some(seconds)
}

pub fn scan(root: &Dir, previous: &Catalog) -> Catalog {
    let mut result = Catalog::default();
    let mut pending = vec![(String::new(), 0usize)];
    let mut visited = 0usize;
    while let Some((parent, depth)) = pending.pop() {
        let entries = match root.read_dir(if parent.is_empty() { "." } else { &parent }) {
            Ok(entries) => entries,
            Err(error) => {
                skip(
                    &mut result,
                    if parent.is_empty() { "." } else { &parent },
                    &error.kind().to_string(),
                );
                continue;
            }
        };
        for entry in entries {
            visited += 1;
            if visited > 100_000 {
                result.scan_errors += 1;
                break;
            }
            let Ok(entry) = entry else {
                result.scan_errors += 1;
                continue;
            };
            let name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(raw) => {
                    let shown = raw.to_string_lossy().into_owned();
                    let path = if parent.is_empty() {
                        shown
                    } else {
                        format!("{parent}/{shown}")
                    };
                    skip(&mut result, &path, "Dateiname ist kein gültiges UTF-8");
                    continue;
                }
            };
            // Hidden files and the file system's own recovery folder.
            if name.starts_with('.') || (parent.is_empty() && name == "lost+found") {
                continue;
            }
            let path = if parent.is_empty() {
                name.clone()
            } else {
                format!("{parent}/{name}")
            };
            let Ok(kind) = entry.file_type() else {
                result.scan_errors += 1;
                continue;
            };
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                result.directories.push(path.clone());
                if depth < 64 {
                    pending.push((path, depth + 1));
                } else {
                    result.scan_errors += 1;
                }
                continue;
            }
            if !kind.is_file() {
                continue;
            }
            let Ok(meta) = root.metadata(&path) else {
                result.scan_errors += 1;
                continue;
            };
            let modified_nanos = meta
                .modified()
                .ok()
                .and_then(|t| t.into_std().duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let id = hex::encode(Sha256::digest(path.as_bytes()));
            if let Some(old) = previous
                .files
                .get(&id)
                .filter(|m| m.bytes == meta.len() && m.modified_nanos == modified_nanos)
            {
                let mut item = old.clone();
                refresh_playback(root, &mut item);
                // Older scans did not read video lengths; fill them in once.
                if item.kind == "video" && item.duration.is_none() {
                    item.duration = video_duration(root, &path);
                }
                result.files.insert(id, item);
                continue;
            }
            let kind = crate::formats::from_path(&path).map_or("file", |format| format.kind);
            let mut item = Media {
                id: id.clone(),
                path: path.clone(),
                name,
                kind: kind.into(),
                title: crate::text::clean(
                    &Path::new(&path)
                        .file_stem()
                        .unwrap_or_default()
                        .to_string_lossy(),
                ),
                artist: None,
                album: None,
                duration: None,
                bytes: meta.len(),
                modified: (modified_nanos / 1_000_000_000) as u64,
                modified_nanos,
                playback: None,
                album_key: None,
                album_artist: None,
                track_number: None,
                disc_number: None,
                cover_id: None,
                series_key: None,
                season_folder: None,
                season: None,
                episode: None,
                playback_path: None,
                hls: false,
                tag_artist: None,
                tag_album: None,
                embedded_art: false,
                subtitles: Vec::new(),
                has_lyrics: false,
                embedded_lyrics: false,
                gain_db: None,
                intro: None,
                added: None,
                censored: false,
                featured: Vec::new(),
                artist_credit: None,
                tag_title: None,
                file_title: String::new(),
            };
            item.file_title = item.title.clone();
            if kind == "video" {
                item.duration = video_duration(root, &path);
            }
            if kind == "audio"
                && let Ok(file) = crate::file_access::open_regular(root, &path)
                && let Ok(probe) = lofty::probe::Probe::new(file).guess_file_type()
                && let Ok(tagged) = probe
                    .options(lofty::config::ParseOptions::new().read_cover_art(true))
                    .read()
            {
                let duration = tagged.properties().duration().as_secs_f64();
                if duration > 0.0 {
                    item.duration = Some(duration);
                }
                if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
                    // Tags with a wrongly declared encoding fall back to
                    // the file or folder name instead of showing "�".
                    item.tag_title = tag.title().and_then(|t| crate::text::tag(&t));
                    // Several artist values (ID3v2.4, Vorbis) become one
                    // credit; "feat." parsing happens in organize.
                    let artists: Vec<String> = tag
                        .get_strings(lofty::tag::ItemKey::TrackArtist)
                        .filter_map(crate::text::tag)
                        .collect();
                    item.tag_artist = match artists.len() {
                        0 => tag.artist().and_then(|s| crate::text::tag(&s)),
                        1 => artists.into_iter().next(),
                        _ => Some(artists.join("; ")),
                    };
                    item.tag_album = tag.album().and_then(|s| crate::text::tag(&s));
                    item.embedded_lyrics = tag
                        .get_string(lofty::tag::ItemKey::Lyrics)
                        .or_else(|| tag.get_string(lofty::tag::ItemKey::UnsyncLyrics))
                        .is_some_and(|l| !l.trim().is_empty());
                    item.gain_db = tag
                        .get_string(lofty::tag::ItemKey::ReplayGainTrackGain)
                        .or_else(|| tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumGain))
                        .and_then(parse_gain);
                    item.censored = tag
                        .get_string(lofty::tag::ItemKey::Comment)
                        .is_some_and(|c| c.contains(CENSORED_MARK));
                    item.track_number = tag.track();
                    item.disc_number = tag.disk();
                }
                item.embedded_art = tagged.tags().iter().any(|tag| !tag.pictures().is_empty());
            }
            refresh_playback(root, &mut item);
            result.files.insert(id, item);
        }
        if visited > 100_000 {
            break;
        }
    }
    result.directories.sort();
    crate::organize::organize(&mut result);
    result.scanned_at = now();
    result
}

/// Written into the comment tag by musik-suchen.py when only a censored version was found.
pub const CENSORED_MARK: &str = "Mediaserver: zensierte Fassung";

#[cfg(test)]
mod tests {
    #[test]
    fn replaygain_values() {
        assert_eq!(super::parse_gain("-7.89 dB"), Some(-7.89));
        assert_eq!(super::parse_gain("+2.5 dB"), Some(2.5));
        assert_eq!(super::parse_gain("-6,1"), Some(-6.1));
        assert_eq!(super::parse_gain("loud"), None);
        assert_eq!(super::parse_gain("-90 dB"), None);
    }
}
