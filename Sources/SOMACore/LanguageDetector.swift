import Foundation

/// Lightweight, dependency-free language detection from a short transcript.
/// It classifies by dominant writing system, which is reliable for the
/// script-distinct languages SOMA is most likely to meet (Korean, Japanese,
/// Chinese, Latin-script languages, Cyrillic, Arabic, Devanagari). It is not a
/// full NLP detector; for ambiguous Latin-script text it falls back to the
/// configured default rather than guessing.
public enum LanguageDetector {
    /// Returns a normalized BCP-47 tag for the dominant script in `text`, or
    /// nil when the text is too short or the script is ambiguous.
    public static func detectTag(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var hangul = 0
        var kana = 0
        var han = 0
        var latin = 0
        var cyrillic = 0
        var arabic = 0
        var devanagari = 0
        var total = 0

        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0xAC00 ... 0xD7A3: hangul += 1; total += 1
            case 0x3040 ... 0x30FF: kana += 1; total += 1
            case 0x4E00 ... 0x9FFF: han += 1; total += 1
            case 0x0400 ... 0x04FF: cyrillic += 1; total += 1
            case 0x0600 ... 0x06FF: arabic += 1; total += 1
            case 0x0900 ... 0x097F: devanagari += 1; total += 1
            case 0x0041 ... 0x005A, 0x0061 ... 0x007A: latin += 1; total += 1
            default: break
            }
        }
        guard total >= 3 else { return nil }

        // Japanese uses Han ideographs too, but kana is the distinguishing mark.
        if kana > 0 { return "ja" }
        if hangul > 0 { return "ko" }
        if han > 0 { return "zh" }
        if cyrillic > 0 { return "ru" }
        if arabic > 0 { return "ar" }
        if devanagari > 0 { return "hi" }
        // Latin script is ambiguous (en/es/fr/de/...). Only commit to English
        // when Latin clearly dominates; otherwise leave it to the default.
        if latin > 0, Double(latin) / Double(total) >= 0.8 { return "en" }
        return nil
    }
}
