import Foundation

/// Encodes an L1-authored opening as a machine event for the Live transport.
/// The event itself contains no conversational language, so it cannot pull
/// the first response away from the participant's selected language.
public enum LiveVoiceOpeningControllerEvent {
    public static func make(opening: String, languageTag: String?) -> String? {
        let text = opening.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let language = languageTag.flatMap(PersonContextFormat.normalizedLanguageTag) ?? "und"
        return """
        ⟦SOMA_EXACT_OPENING language=\(language) delivery=once_then_listen⟧
        \(text)
        ⟦/SOMA_EXACT_OPENING⟧
        """
    }
}
