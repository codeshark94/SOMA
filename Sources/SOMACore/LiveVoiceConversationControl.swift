import Foundation

public enum LiveVoiceConversationControlIntent: Equatable, Sendable {
    case endConversation
}

/// Recognizes explicit participant control commands that must be executed by
/// the local session owner instead of depending on a conversational model to
/// select a tool. The grammar is deliberately narrow: it accepts only direct
/// imperatives about the active voice/conversation channel or an unambiguous
/// request for silence, and rejects negated commands.
public struct LiveVoiceConversationControlClassifier: Sendable {
    public init() {}

    public func classify(_ transcript: String) -> LiveVoiceConversationControlIntent? {
        let normalized = Self.normalized(transcript)
        guard !normalized.isEmpty else { return nil }
        let compact = normalized.replacingOccurrences(of: " ", with: "")

        if Self.containsAny(compact, Self.negatedControls) {
            return nil
        }
        if Self.containsAny(compact, Self.directSilenceControls) {
            return .endConversation
        }
        if Self.containsAny(compact, Self.koreanStandaloneControls) {
            return .endConversation
        }

        let hasChannel = Self.containsAny(compact, Self.channelTerms)
        let hasTermination = Self.containsAny(compact, Self.terminationTerms)
        if hasChannel && hasTermination {
            return .endConversation
        }

        let words = Set(normalized.split(separator: " ").map(String.init))
        let hasEnglishChannel = !words.isDisjoint(with: Self.englishChannelWords)
        let hasEnglishTermination = Self.englishTerminationPhrases.contains {
            normalized.contains($0)
        }
        if hasEnglishChannel && hasEnglishTermination {
            return .endConversation
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        let folded = text
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(String(scalar))
                : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private static let negatedControls = [
        "종료하지마", "종료하지말", "끝내지마", "끝내지말", "끊지마", "끊지말",
        "중단하지마", "중단하지말", "끄지마", "끄지말", "꺼지마", "꺼지말",
        "그만하지마", "그만하지말", "말그만하지마", "말그만하지말",
        "donotstop", "dontstop", "donotend", "dontend", "donotclose", "dontclose",
        "止めないで", "終了しないで", "不要结束", "不要結束", "别关闭", "別關閉",
    ]

    private static let directSilenceControls = [
        "말그만", "그만말해", "그만얘기해", "조용히해", "조용해", "닥쳐",
        "bequiet", "stoptalking", "stoplistening", "shutup",
        "黙って", "話すのをやめて", "安静", "安靜", "别说了", "別說了",
    ]

    private static let koreanStandaloneControls = [
        "음성끊어", "음성꺼", "음성종료해", "음성중단해", "대화끝내", "대화종료해",
        "세션끝내", "세션종료해", "세션끊어", "종료해줘", "종료시켜", "종료안됐",
    ]

    private static let channelTerms = [
        "음성", "보이스", "대화", "대화창", "세션", "라이브", "마이크",
        "音声", "会話", "セッション", "语音", "語音", "对话", "對話", "会话", "會話",
    ]

    private static let terminationTerms = [
        "종료해", "종료시켜", "종료하자", "종료할게", "끝내줘", "끝내자", "끝낼게",
        "끊어", "끊을게", "중단해", "중단하자", "중단할게", "꺼줘", "꺼라", "끄자", "끄고",
        "終了して", "終了しよう", "止めて", "切って",
        "请结束", "請結束", "结束吧", "結束吧", "请关闭", "請關閉", "停止语音", "停止語音",
    ]

    private static let englishChannelWords: Set<String> = [
        "voice", "audio", "conversation", "session", "listening", "talking", "microphone", "mic",
    ]

    private static let englishTerminationPhrases = [
        "stop", "end", "close", "turn off", "shut down",
    ]
}
