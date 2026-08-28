import Foundation

public struct LiveVoiceLaunchGate: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case inactive
        case starting
        case active
    }

    public private(set) var phase: Phase = .inactive
    public private(set) var retryAfterNS: UInt64 = 0

    public init() {}

    public mutating func beginLaunch(at monotonicNS: UInt64) -> Bool {
        guard phase == .inactive, monotonicNS >= retryAfterNS else { return false }
        phase = .starting
        return true
    }

    public mutating func observeActive() {
        phase = .active
        retryAfterNS = 0
    }

    public mutating func observeEnded() {
        phase = .inactive
        retryAfterNS = 0
    }

    public mutating func fail(
        at monotonicNS: UInt64,
        retryMilliseconds: UInt64 = 5_000
    ) {
        phase = .inactive
        let delta = retryMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        if delta.overflow {
            retryAfterNS = UInt64.max
            return
        }
        let deadline = monotonicNS.addingReportingOverflow(delta.partialValue)
        retryAfterNS = deadline.overflow ? UInt64.max : deadline.partialValue
    }
}

/// Owns the local lifetime of one active Live voice session. Only confirmed
/// user activity renews this lease; assistant speech must not keep an idle
/// microphone session alive indefinitely.
public struct LiveVoiceSessionInactivityGate: Equatable, Sendable {
    public let timeoutMilliseconds: UInt64
    public private(set) var deadlineNS: UInt64?

    public init(timeoutMilliseconds: UInt64 = 60_000) {
        precondition(timeoutMilliseconds > 0)
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    @discardableResult
    public mutating func activate(at monotonicNS: UInt64) -> UInt64 {
        renew(at: monotonicNS)
    }

    @discardableResult
    public mutating func recordUserActivity(at monotonicNS: UInt64) -> UInt64? {
        guard deadlineNS != nil else { return nil }
        return renew(at: monotonicNS)
    }

    public func shouldClose(at monotonicNS: UInt64) -> Bool {
        guard let deadlineNS else { return false }
        return monotonicNS >= deadlineNS
    }

    public mutating func close() {
        deadlineNS = nil
    }

    @discardableResult
    private mutating func renew(at monotonicNS: UInt64) -> UInt64 {
        let delta = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let result = monotonicNS.addingReportingOverflow(delta.partialValue)
        let deadline = delta.overflow || result.overflow ? UInt64.max : result.partialValue
        deadlineNS = deadline
        return deadline
    }
}

/// Detects the narrow failure mode where SOMA's own rendered speech is picked
/// up by the camera microphone and returned by the realtime service as a user
/// transcript.  It deliberately compares only complete, substantial text from
/// the immediately preceding assistant turn; ordinary short acknowledgements
/// and a participant's independent reply remain admissible.
public struct LiveVoiceTranscriptEchoGuard: Sendable {
    private struct AssistantTurn: Sendable {
        let normalizedText: String
        let observedNS: UInt64
    }

    private let maximumAgeNS: UInt64
    private let minimumComparableCharacters: Int
    private var lastAssistantTurn: AssistantTurn?

    public init(
        maximumAgeMilliseconds: UInt64 = 12_000,
        minimumComparableCharacters: Int = 8
    ) {
        precondition(maximumAgeMilliseconds > 0)
        precondition(minimumComparableCharacters > 0)
        maximumAgeNS = maximumAgeMilliseconds * 1_000_000
        self.minimumComparableCharacters = minimumComparableCharacters
    }

    public mutating func recordAssistantTranscript(_ text: String, at monotonicNS: UInt64) {
        let normalized = Self.normalize(text)
        guard normalized.count >= minimumComparableCharacters else { return }
        lastAssistantTurn = AssistantTurn(normalizedText: normalized, observedNS: monotonicNS)
    }

    public mutating func rejectsUserTranscript(_ text: String, at monotonicNS: UInt64) -> Bool {
        guard let lastAssistantTurn,
              monotonicNS >= lastAssistantTurn.observedNS,
              monotonicNS - lastAssistantTurn.observedNS <= maximumAgeNS else {
            if let lastAssistantTurn, monotonicNS >= lastAssistantTurn.observedNS {
                self.lastAssistantTurn = nil
            }
            return false
        }
        let normalized = Self.normalize(text)
        guard normalized.count >= minimumComparableCharacters else {
            return false
        }
        guard normalized == lastAssistantTurn.normalizedText else { return false }
        self.lastAssistantTurn = nil
        return true
    }

    private static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            .lowercased()
    }

}

/// Keeps microphone turns from being assembled out of the assistant's own
/// rendered audio. The short trailing interval lets the microphone settle
/// after output playback ends without turning normal silence into a user turn.
public struct LiveVoicePlaybackCaptureGate: Sendable {
    private let trailingSuppressionNS: UInt64
    private var assistantOutputActive = false
    private var suppressUntilNS: UInt64 = 0

    public init(trailingSuppressionMilliseconds: UInt64 = 500) {
        precondition(trailingSuppressionMilliseconds > 0)
        trailingSuppressionNS = trailingSuppressionMilliseconds * 1_000_000
    }

    public mutating func beginAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputActive = true
        suppressUntilNS = max(suppressUntilNS, monotonicNS)
    }

    public mutating func endAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputActive = false
        let deadline = monotonicNS.addingReportingOverflow(trailingSuppressionNS)
        suppressUntilNS = deadline.overflow ? UInt64.max : max(suppressUntilNS, deadline.partialValue)
    }

    public func suppressesMicrophone(at monotonicNS: UInt64) -> Bool {
        assistantOutputActive || monotonicNS < suppressUntilNS
    }
}
