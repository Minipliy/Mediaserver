//! Optional HLS copies made by scripts/prepare-hls.py. They belong only to the
//! exact original path and file stat; anything else means "no copy", and the
//! app plays the normal file.

use crate::catalog::Media;
use cap_std::fs::Dir;
use serde::Deserialize;
use std::io::Read;

const REVISION: u32 = 1;

#[derive(Deserialize)]
struct Manifest {
    version: u32,
    revision: u32,
    source_path: String,
    source_bytes: u64,
    source_modified_ns: u128,
}

pub(crate) fn directory(id: &str) -> String {
    format!(".miniply-hls/{id}")
}

pub(crate) fn available(root: &Dir, media: &Media) -> bool {
    if media.kind != "video" {
        return false;
    }
    let directory = directory(&media.id);
    let Ok(file) =
        crate::file_access::open_regular_nofollow(root, format!("{directory}/manifest.json"))
    else {
        return false;
    };
    let mut data = Vec::new();
    if file.take(64 * 1024 + 1).read_to_end(&mut data).is_err() || data.len() > 64 * 1024 {
        return false;
    }
    let Ok(manifest) = serde_json::from_slice::<Manifest>(&data) else {
        return false;
    };
    manifest.version == 1
        && manifest.revision == REVISION
        && manifest.source_path == media.path
        && manifest.source_bytes == media.bytes
        && manifest.source_modified_ns == media.modified_nanos
        && crate::file_access::open_regular_nofollow(root, format!("{directory}/master.m3u8"))
            .is_ok()
}

/// Only the names the script writes, with their content type.
pub(crate) fn content_type(file: &str) -> Option<&'static str> {
    if file == "master.m3u8" {
        return Some("application/vnd.apple.mpegurl");
    }
    let (rendition, name) = file.split_once('/')?;
    let index = rendition.strip_prefix('v')?;
    if index.is_empty() || index.len() > 2 || !index.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if name == "index.m3u8" {
        return Some("application/vnd.apple.mpegurl");
    }
    let number = name.strip_prefix("seg")?.strip_suffix(".ts")?;
    (!number.is_empty() && number.len() <= 8 && number.bytes().all(|b| b.is_ascii_digit()))
        .then_some("video/mp2t")
}

#[cfg(test)]
mod tests {
    use super::content_type;

    #[test]
    fn only_generated_names_are_served() {
        assert!(content_type("master.m3u8").is_some());
        assert!(content_type("v0/index.m3u8").is_some());
        assert_eq!(content_type("v12/seg00001.ts"), Some("video/mp2t"));
        for bad in [
            "manifest.json",
            "../master.m3u8",
            "v0/../../x.ts",
            "v0/seg.ts",
            "v0/sega.ts",
            "v/index.m3u8",
            "vx/index.m3u8",
            "v0/v1/index.m3u8",
            "",
        ] {
            assert!(content_type(bad).is_none(), "{bad}");
        }
    }
}
