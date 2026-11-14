use crate::catalog::{Media, PlaybackVariant};
use cap_std::fs::Dir;
use serde::Deserialize;
use std::{fs::File, io::Read};

#[derive(Deserialize)]
struct Manifest {
    version: u32,
    source_path: String,
    source_bytes: u64,
    source_modified_ns: u128,
    filename: String,
    bytes: u64,
}

pub(crate) struct PreparedPlayback {
    pub file: File,
    pub path: String,
    pub variant: PlaybackVariant,
}

/// A prepared file belongs only to the exact original path and source stat.
/// Invalid, missing or obsolete entries simply use the original media file.
pub(crate) fn open(
    root: &Dir,
    media: &Media,
    source_bytes: u64,
    source_modified_ns: u128,
) -> Option<PreparedPlayback> {
    let expected_filename = match media.kind.as_str() {
        "video" => "playback.mp4",
        "audio" => "playback.m4a",
        _ => return None,
    };
    let directory = format!(".miniply-playback/{}", media.id);
    let manifest =
        crate::file_access::open_regular_nofollow(root, format!("{directory}/manifest.json"))
            .ok()?;
    let mut data = Vec::new();
    manifest.take(64 * 1024 + 1).read_to_end(&mut data).ok()?;
    if data.len() > 64 * 1024 {
        return None;
    }
    let manifest: Manifest = serde_json::from_slice(&data).ok()?;
    if manifest.version != 1
        || manifest.source_path != media.path
        || manifest.source_bytes != source_bytes
        || manifest.source_modified_ns != source_modified_ns
        || manifest.filename != expected_filename
        || manifest.bytes == 0
    {
        return None;
    }
    let path = format!("{directory}/{}", manifest.filename);
    let file = crate::file_access::open_regular_nofollow(root, &path).ok()?;
    if file.metadata().ok()?.len() != manifest.bytes {
        return None;
    }
    Some(PreparedPlayback {
        file,
        path,
        variant: PlaybackVariant {
            file_extension: if media.kind == "video" { "mp4" } else { "m4a" }.into(),
            bytes: manifest.bytes,
        },
    })
}
