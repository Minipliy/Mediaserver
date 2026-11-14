//! Display-only text repair. File paths and IDs are never changed.

/// Samba's `vfs_fruit` (default `fruit:encoding = private`) and the macOS SMB
/// client store characters that are illegal on Windows in the Unicode private
/// use area (Services for Macintosh mapping). Map them back for display.
fn unmap_private(c: char) -> Option<char> {
    Some(match c as u32 {
        0xF001..=0xF01F => return None, // control characters: drop
        0xF020 => '"',
        0xF021 => '*',
        0xF022 => ':',
        0xF023 => '<',
        0xF024 => '>',
        0xF025 => '?',
        0xF026 => '\\',
        0xF027 => '|',
        0xF028 => ' ',
        0xF029 => '.',
        _ => c,
    })
}

/// "MÃ¶tley CrÃ¼e" -> "Mötley Crüe": text that was UTF-8 but decoded as
/// Latin-1. Only applied when the result is valid UTF-8 and really differs.
fn fix_mojibake(value: &str) -> Option<String> {
    if value.is_ascii() || value.chars().any(|c| c as u32 > 0xFF) {
        return None;
    }
    if !value.chars().any(|c| matches!(c as u32, 0xC2..=0xF4)) {
        return None;
    }
    let bytes: Vec<u8> = value.chars().map(|c| c as u32 as u8).collect();
    let fixed = String::from_utf8(bytes).ok()?;
    (fixed != value && !fixed.is_ascii()).then_some(fixed)
}

/// Clean a name for display: private-use mapping, mojibake, control
/// characters and surrounding whitespace.
pub fn clean(value: &str) -> String {
    let mapped: String = value.chars().filter_map(unmap_private).collect();
    let fixed = fix_mojibake(&mapped).unwrap_or(mapped);
    fixed
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .to_owned()
}

/// A tag value is unusable if it still contains replacement characters
/// (wrongly declared encoding) after cleaning.
pub fn tag(value: &str) -> Option<String> {
    let cleaned = clean(value);
    (!cleaned.is_empty() && !cleaned.contains('\u{FFFD}')).then_some(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_use_characters_from_samba_are_restored() {
        assert_eq!(clean("What\u{F025}s Up\u{F025}"), "What?s Up?");
        assert_eq!(clean("AC\u{F022}DC"), "AC:DC");
        assert_eq!(clean("\u{F020}Quote\u{F020}"), "\"Quote\"");
    }

    #[test]
    fn latin1_mojibake_is_repaired() {
        assert_eq!(clean("MÃ¶tley CrÃ¼e"), "Mötley Crüe");
        assert_eq!(clean("BeyoncÃ©"), "Beyoncé");
        assert_eq!(clean("Mötley Crüe"), "Mötley Crüe");
        assert_eq!(clean("Café"), "Café");
        assert_eq!(
            clean("Sigur Rós – Ágætis byrjun"),
            "Sigur Rós – Ágætis byrjun"
        );
    }

    #[test]
    fn broken_tags_are_rejected() {
        assert_eq!(tag("Bj\u{FFFD}rk"), None);
        assert_eq!(tag("  "), None);
        assert_eq!(tag("Björk").as_deref(), Some("Björk"));
    }
}
