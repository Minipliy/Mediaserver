use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct MediaFormat {
    pub kind: &'static str,
    pub content_type: &'static str,
}

/// Extension-based library grouping and HTTP container type share one mapping.
/// This does not inspect codecs or promise that an iPhone can decode the file.
/// In particular, playlist manifests remain ordinary downloadable files.
pub(crate) fn from_path(path: &str) -> Option<MediaFormat> {
    let extension = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    let (kind, content_type) = match extension.as_str() {
        "mp3" | "mp2" | "mp1" => ("audio", "audio/mpeg"),
        "m4a" | "m4b" | "m4r" => ("audio", "audio/mp4"),
        "aac" | "adts" => ("audio", "audio/aac"),
        "flac" => ("audio", "audio/flac"),
        "wav" | "wave" => ("audio", "audio/wav"),
        "aiff" | "aif" | "aifc" => ("audio", "audio/aiff"),
        "ogg" | "oga" | "opus" | "spx" => ("audio", "audio/ogg"),
        "ape" => ("audio", "audio/x-ape"),
        "wv" => ("audio", "audio/wavpack"),
        "wma" => ("audio", "audio/x-ms-wma"),
        "weba" => ("audio", "audio/webm"),
        "caf" => ("audio", "audio/x-caf"),
        "ac3" => ("audio", "audio/ac3"),
        "eac3" => ("audio", "audio/eac3"),
        "dts" => ("audio", "audio/vnd.dts"),
        "amr" => ("audio", "audio/amr"),
        "au" | "snd" => ("audio", "audio/basic"),
        // Keep existing ALAC indexing, without claiming a container for a raw
        // codec extension. ALAC in its usual M4A container is audio/mp4 above.
        "alac" => ("audio", "application/octet-stream"),
        "mp4" | "m4v" => ("video", "video/mp4"),
        "mov" | "qt" => ("video", "video/quicktime"),
        "mkv" => ("video", "video/x-matroska"),
        "avi" => ("video", "video/x-msvideo"),
        "webm" => ("video", "video/webm"),
        "mpeg" | "mpg" | "mpe" | "m1v" | "m2v" | "vob" => ("video", "video/mpeg"),
        "ts" => ("video", "video/mp2t"),
        "m2ts" | "mts" => ("video", "video/vnd.dlna.mpeg-tts"),
        "ogv" => ("video", "video/ogg"),
        "3gp" | "3gpp" => ("video", "video/3gpp"),
        "3g2" => ("video", "video/3gpp2"),
        "wmv" => ("video", "video/x-ms-wmv"),
        "asf" => ("video", "video/x-ms-asf"),
        "flv" => ("video", "video/x-flv"),
        _ => return None,
    };
    Some(MediaFormat { kind, content_type })
}

#[cfg(test)]
mod tests {
    use super::from_path;

    #[test]
    fn extension_grouping_ignores_ascii_case() {
        for extension in "mp3 mp2 mp1 m4a m4b m4r aac adts flac wav wave aiff aif aifc ogg oga opus spx ape wv wma weba caf ac3 eac3 dts amr au snd alac mp4 m4v mov qt mkv avi webm mpeg mpg mpe m1v m2v vob ts m2ts mts ogv 3gp 3gpp 3g2 wmv asf flv".split_whitespace() {
            let lower = from_path(&format!("Folder.with.dots/Film or song.{extension}"));
            let upper = from_path(&format!("Film or song.{}", extension.to_ascii_uppercase()));
            assert!(lower.is_some(), "{extension}");
            assert_eq!(lower, upper, "{extension}");
        }
        assert_eq!(from_path("Mixed.MoV"), from_path("Mixed.mov"));
    }

    #[test]
    fn playlists_and_unknown_files_are_not_media() {
        for path in [
            "playlist.m3u",
            "playlist.M3U8",
            "playlist.pls",
            "captions.srt",
            "document.txt",
            "no-extension",
            "video.mp4.txt",
        ] {
            assert!(from_path(path).is_none(), "{path}");
        }
    }
}
