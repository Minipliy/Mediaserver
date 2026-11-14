//! Background analysis with FFmpeg, results kept in SQLite:
//!
//! - Loudness of songs without ReplayGain tags (EBU R128), so the app can level
//!   old and new downloads alike. Stored as a ReplayGain-style gain (reference -18 LUFS).
//! - Intros of series episodes: a stretch of sound at the start that is the same in
//!   every episode of a season. Only when all episodes share it is an intro stored,
//!   so "Intro überspringen" never jumps over something that differs.
//!
//! Disable with `MINIPLY_ANALYSIS=0`.

use crate::{AppState, catalog::Catalog};
use serde::Serialize;
use std::{collections::HashMap, path::Path, process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command};

/// ReplayGain 2 reference loudness.
const REFERENCE_LUFS: f32 = -18.0;
/// Seconds from the start of an episode that are searched for the intro.
const INTRO_WINDOW_SECONDS: u32 = 360;
const SAMPLE_RATE: usize = 8000;
/// One fingerprint per tenth of a second.
const STEP: usize = SAMPLE_RATE / 10;
const FRAME: usize = 2048;
/// 33 bands between 300 and 2000 Hz give 32 bits per fingerprint (Haitsma and Kalker).
const BANDS: usize = 33;
/// An intro is at least 15 seconds long.
const MIN_INTRO_STEPS: usize = 150;
/// Below this level a stretch counts as silence, which says nothing about an intro.
const SILENCE_DB: f32 = -45.0;
/// The same sound differs in a few bits after encoding; unrelated sound in about 16 of 32.
const MAX_BIT_ERRORS: u32 = 9;
/// Short differing moments (a cut, a sound effect) do not end a match.
const ALLOWED_GAP: usize = 5;

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Intro {
    pub start: f64,
    pub end: f64,
}

/// Results by media ID, each with the file's modification time it belongs to.
#[derive(Default)]
pub struct Analysis {
    pub loudness: HashMap<String, (u64, Option<f32>)>,
    pub intros: HashMap<String, (u64, Option<Intro>)>,
}

impl Analysis {
    /// Fill gain and intro of the catalog where the file has not changed since.
    pub fn apply(&self, catalog: &mut Catalog) {
        for media in catalog.files.values_mut() {
            if media.kind == "audio" && media.gain_db.is_none() {
                if let Some((modified, Some(gain))) = self.loudness.get(&media.id)
                    && *modified == media.modified
                {
                    media.gain_db = Some(*gain);
                }
            } else if media.kind == "video"
                && let Some((modified, intro)) = self.intros.get(&media.id)
                && *modified == media.modified
            {
                media.intro = *intro;
            }
        }
    }

    fn loudness_due(&self, id: &str, modified: u64) -> bool {
        self.loudness.get(id).is_none_or(|(m, _)| *m != modified)
    }

    fn intro_due(&self, id: &str, modified: u64) -> bool {
        self.intros.get(id).is_none_or(|(m, _)| *m != modified)
    }
}

pub fn enabled() -> bool {
    !matches!(
        std::env::var("MINIPLY_ANALYSIS")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

/// Integrated loudness from FFmpeg's ebur128 summary ("I:  -8.6 LUFS").
pub fn parse_loudness(log: &str) -> Option<f32> {
    let summary = &log[log.rfind("Summary:")?..];
    let line = summary.lines().find(|l| l.trim_start().starts_with("I:"))?;
    let value: f32 = line.trim_start()[2..]
        .split_whitespace()
        .next()?
        .parse()
        .ok()?;
    (value.is_finite() && value > -70.0).then_some(value)
}

/// Gain that brings a song to the reference loudness, limited to sensible values.
pub fn gain_for(loudness: f32) -> f32 {
    ((REFERENCE_LUFS - loudness) * 100.0).round() / 100.0
}

async fn measure_loudness(path: &Path) -> Option<f32> {
    let mut child = Command::new("nice")
        .args(["-n", "10", "ffmpeg", "-nostdin", "-hide_banner", "-i"])
        .arg(path)
        .args(["-vn", "-sn", "-af", "ebur128", "-f", "null", "-"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut stderr = child.stderr.take()?;
    let read = async {
        let mut log = String::new();
        stderr.read_to_string(&mut log).await.ok()?;
        Some(log)
    };
    let log = tokio::time::timeout(Duration::from_secs(300), read)
        .await
        .ok()??;
    let _ = tokio::time::timeout(Duration::from_secs(10), child.wait()).await;
    parse_loudness(&log).map(|l| gain_for(l).clamp(-20.0, 15.0))
}

/// One step of the fingerprint: 32 bits for the shape of the spectrum and how it changes,
/// plus the level, so that silence never counts as the same sound.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Print {
    pub bits: u32,
    pub level: f32,
}

/// In-place radix-2 FFT of a power-of-two length.
fn fft(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut length = 2;
    while length <= n {
        let angle = -2.0 * std::f32::consts::PI / length as f32;
        for start in (0..n).step_by(length) {
            for k in 0..length / 2 {
                let (sin, cos) = (angle * k as f32).sin_cos();
                let (a, b) = (start + k, start + k + length / 2);
                let (tr, ti) = (re[b] * cos - im[b] * sin, re[b] * sin + im[b] * cos);
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
        length <<= 1;
    }
}

/// Audio fingerprint after Haitsma and Kalker, one per tenth of a second.
pub fn features(samples: &[i16]) -> Vec<Print> {
    if samples.len() < FRAME {
        return Vec::new();
    }
    let hz_per_bin = SAMPLE_RATE as f32 / FRAME as f32;
    let edges: Vec<usize> = (0..=BANDS)
        .map(|i| {
            let hz = 300.0 * (2000.0f32 / 300.0).powf(i as f32 / BANDS as f32);
            (hz / hz_per_bin).round() as usize
        })
        .collect();
    let window: Vec<f32> = (0..FRAME)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / FRAME as f32).cos())
        .collect();
    let mut previous: Option<[f32; BANDS]> = None;
    let mut prints = Vec::new();
    let (mut re, mut im) = (vec![0f32; FRAME], vec![0f32; FRAME]);
    for start in (0..=samples.len() - FRAME).step_by(STEP) {
        let mut power = 0f32;
        for i in 0..FRAME {
            let v = f32::from(samples[start + i]) / 32768.0;
            power += v * v;
            re[i] = v * window[i];
            im[i] = 0.0;
        }
        fft(&mut re, &mut im);
        let mut bands = [0f32; BANDS];
        for (band, energy) in bands.iter_mut().enumerate() {
            *energy = (edges[band]..edges[band + 1].max(edges[band] + 1))
                .map(|k| re[k] * re[k] + im[k] * im[k])
                .sum();
        }
        if let Some(last) = previous {
            let mut bits = 0u32;
            for m in 0..BANDS - 1 {
                if (bands[m] - bands[m + 1]) - (last[m] - last[m + 1]) > 0.0 {
                    bits |= 1 << m;
                }
            }
            prints.push(Print {
                bits,
                level: 10.0 * (power / FRAME as f32 + 1e-9).log10(),
            });
        }
        previous = Some(bands);
    }
    prints
}

async fn episode_features(path: &Path) -> Option<Vec<Print>> {
    let mut child = Command::new("nice")
        .args([
            "-n",
            "10",
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-t",
        ])
        .arg(INTRO_WINDOW_SECONDS.to_string())
        .arg("-i")
        .arg(path)
        .args(["-vn", "-sn", "-ac", "1", "-ar"])
        .arg(SAMPLE_RATE.to_string())
        .args(["-f", "s16le", "pipe:1"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let read = async {
        let mut data = Vec::new();
        stdout.read_to_end(&mut data).await.ok()?;
        Some(data)
    };
    let data = tokio::time::timeout(Duration::from_secs(600), read)
        .await
        .ok()??;
    let _ = tokio::time::timeout(Duration::from_secs(10), child.wait()).await;
    let samples: Vec<i16> = data
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    let found = features(&samples);
    (found.len() >= MIN_INTRO_STEPS).then_some(found)
}

fn similar(a: Print, b: Print) -> bool {
    a.level > SILENCE_DB && b.level > SILENCE_DB && (a.bits ^ b.bits).count_ones() <= MAX_BIT_ERRORS
}

/// Longest stretch that sounds the same in both: (start in a, start in b, length), in steps.
pub fn longest_match(a: &[Print], b: &[Print]) -> Option<(usize, usize, usize)> {
    let mut best: Option<(usize, usize, usize)> = None;
    let (la, lb) = (a.len() as isize, b.len() as isize);
    for shift in -(lb - 1)..la {
        // Position i in a meets position i - shift in b.
        let first = shift.max(0);
        let last = la.min(lb + shift);
        let mut run: Option<(isize, isize)> = None;
        let finish = |run: (isize, isize), best: &mut Option<(usize, usize, usize)>| {
            let length = (run.1 - run.0 + 1) as usize;
            if best.is_none_or(|b| length > b.2) {
                *best = Some((run.0 as usize, (run.0 - shift) as usize, length));
            }
        };
        for i in first..last {
            if similar(a[i as usize], b[(i - shift) as usize]) {
                run = Some(run.map_or((i, i), |(start, _)| (start, i)));
            } else if let Some(current) = run
                && (i - current.1) as usize > ALLOWED_GAP
            {
                finish(current, &mut best);
                run = None;
            }
        }
        if let Some(current) = run {
            finish(current, &mut best);
        }
    }
    best.filter(|b| b.2 >= MIN_INTRO_STEPS)
}

/// The intro of every episode, or None for all when they do not share one.
/// `episodes[0]` is the reference; each other episode must contain the same stretch.
pub fn common_intro(episodes: &[Vec<Print>]) -> Option<Vec<Intro>> {
    let (reference, others) = episodes.split_first()?;
    if others.is_empty() {
        return None;
    }
    let mut start = 0usize;
    let mut end = usize::MAX;
    let mut shifts = Vec::new();
    for other in others {
        let (in_reference, in_other, length) = longest_match(reference, other)?;
        start = start.max(in_reference);
        end = end.min(in_reference + length);
        shifts.push(in_other as isize - in_reference as isize);
    }
    if end <= start || end - start < MIN_INTRO_STEPS {
        return None;
    }
    let seconds = |step: isize| step as f64 * STEP as f64 / SAMPLE_RATE as f64;
    let mut intros = vec![Intro {
        start: seconds(start as isize),
        end: seconds(end as isize),
    }];
    for shift in shifts {
        intros.push(Intro {
            start: seconds(start as isize + shift),
            end: seconds(end as isize + shift),
        });
    }
    Some(intros)
}

/// Background worker: loudness of new songs, then intros of new seasons.
pub fn spawn(state: AppState) {
    if !enabled() {
        tracing::info!("analysis disabled (MINIPLY_ANALYSIS=0)");
        return;
    }
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(20)).await;
        loop {
            loudness_pass(&state).await;
            intro_pass(&state).await;
            tokio::time::sleep(Duration::from_secs(600)).await;
        }
    });
}

async fn loudness_pass(state: &AppState) {
    let todo: Vec<(String, String, u64)> = {
        let catalog = state.catalog.read().await;
        let analysis = state.analysis.read().await;
        let mut list: Vec<_> = catalog
            .files
            .values()
            .filter(|m| {
                m.kind == "audio" && m.gain_db.is_none() && analysis.loudness_due(&m.id, m.modified)
            })
            .map(|m| (m.id.clone(), m.path.clone(), m.modified))
            .collect();
        list.sort_by(|a, b| a.1.cmp(&b.1));
        list
    };
    if !todo.is_empty() {
        tracing::info!(count = todo.len(), "analysis: measuring loudness");
    }
    for (id, path, modified) in todo {
        let gain = measure_loudness(&state.root_path.join(&path)).await;
        if state
            .store
            .save_loudness(id.clone(), modified, gain)
            .await
            .is_err()
        {
            return;
        }
        state
            .analysis
            .write()
            .await
            .loudness
            .insert(id.clone(), (modified, gain));
        if let Some(gain) = gain
            && let Some(media) = state.catalog.write().await.files.get_mut(&id)
            && media.modified == modified
            && media.gain_db.is_none()
        {
            media.gain_db = Some(gain);
        }
    }
}

async fn intro_pass(state: &AppState) {
    // Episodes of one season, in order; a season counts once one of them is new or changed.
    let seasons: Vec<Vec<(String, String, u64)>> = {
        let catalog = state.catalog.read().await;
        let analysis = state.analysis.read().await;
        let mut groups: HashMap<(String, String), Vec<&crate::catalog::Media>> = HashMap::new();
        for media in catalog.files.values().filter(|m| m.kind == "video") {
            if let Some(series) = &media.series_key {
                let season = media
                    .season
                    .map(|s| s.to_string())
                    .or_else(|| media.season_folder.clone())
                    .unwrap_or_default();
                groups
                    .entry((series.clone(), season))
                    .or_default()
                    .push(media);
            }
        }
        let mut seasons: Vec<_> = groups
            .into_values()
            .filter(|episodes| episodes.len() >= 2)
            .filter(|episodes| {
                episodes
                    .iter()
                    .any(|m| analysis.intro_due(&m.id, m.modified))
            })
            .map(|mut episodes| {
                episodes.sort_by(|a, b| (a.episode, &a.path).cmp(&(b.episode, &b.path)));
                episodes
                    .into_iter()
                    .map(|m| (m.id.clone(), m.path.clone(), m.modified))
                    .collect::<Vec<_>>()
            })
            .collect();
        seasons.sort();
        seasons
    };
    for season in seasons {
        let mut found = Vec::new();
        for (_, path, _) in &season {
            match episode_features(&state.root_path.join(path)).await {
                Some(features) => found.push(features),
                None => break,
            }
        }
        let intros = (found.len() == season.len())
            .then(|| common_intro(&found))
            .flatten();
        tracing::info!(
            episodes = season.len(),
            found = intros.is_some(),
            "analysis: intro of a season"
        );
        for (position, (id, _, modified)) in season.iter().enumerate() {
            let intro = intros.as_ref().map(|all| all[position]);
            if state
                .store
                .save_intro(id.clone(), *modified, intro)
                .await
                .is_err()
            {
                return;
            }
            state
                .analysis
                .write()
                .await
                .intros
                .insert(id.clone(), (*modified, intro));
            if let Some(media) = state.catalog.write().await.files.get_mut(id)
                && media.modified == *modified
            {
                media.intro = intro;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loudness_from_ffmpeg_summary() {
        let log = "[Parsed_ebur128_0] t: 1 I: -30.0 LUFS\n[Parsed_ebur128_0 @ 0x1] Summary:\n\n  Integrated loudness:\n    I:          -8.6 LUFS\n    Threshold: -18.9 LUFS\n";
        assert_eq!(parse_loudness(log), Some(-8.6));
        assert_eq!(gain_for(-8.6), -9.4);
        assert_eq!(parse_loudness("no summary"), None);
    }

    /// Random fingerprints: unrelated sound, as different as real audio.
    fn theme(length: usize, seed: usize) -> Vec<Print> {
        let mut state = seed as u64 * 2_654_435_761 + 1;
        (0..length)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                Print {
                    bits: state as u32,
                    level: -20.0,
                }
            })
            .collect()
    }

    #[test]
    fn intro_only_when_every_episode_has_it() {
        let intro = theme(300, 1);
        let episode = |before: usize, seed: usize| {
            let mut all = theme(before, seed * 31 + 5);
            all.extend(intro.iter().copied());
            all.extend(theme(900, seed * 17 + 9));
            all
        };
        let found =
            common_intro(&[episode(100, 1), episode(250, 2), episode(0, 3)]).expect("shared intro");
        assert_eq!(
            found[0],
            Intro {
                start: 10.0,
                end: 40.0
            }
        );
        assert_eq!(
            found[1],
            Intro {
                start: 25.0,
                end: 55.0
            }
        );
        assert_eq!(
            found[2],
            Intro {
                start: 0.0,
                end: 30.0
            }
        );
        // One episode without it: no intro anywhere.
        assert_eq!(
            common_intro(&[episode(100, 1), episode(250, 2), theme(1500, 77)]),
            None
        );
        // A single episode cannot show that anything repeats.
        assert_eq!(common_intro(&[episode(100, 1)]), None);
    }

    #[test]
    fn silence_is_no_intro() {
        let quiet = vec![
            Print {
                bits: 0,
                level: -80.0
            };
            2000
        ];
        assert_eq!(common_intro(&[quiet.clone(), quiet]), None);
    }

    #[test]
    fn same_sound_same_print_noise_differs() {
        let tone: Vec<i16> = (0..80_000)
            .map(|i| ((i as f32 * 0.07).sin() * (i as f32 * 0.0011).sin() * 12_000.0) as i16)
            .collect();
        let a = features(&tone);
        let b = features(&tone);
        assert!(!a.is_empty() && a == b);
        let mut state = 7u32;
        let noise: Vec<i16> = (0..80_000)
            .map(|_| {
                state = state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                (state >> 17) as i16 - 16_000
            })
            .collect();
        let mut state = 99u32;
        let other: Vec<i16> = (0..80_000)
            .map(|_| {
                state = state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                (state >> 17) as i16 - 16_000
            })
            .collect();
        assert_eq!(
            longest_match(&features(&noise), &features(&other)),
            None,
            "two noises are not one intro"
        );
    }
}
