import Foundation

public struct SpeechTurnSegmentationConfiguration: Equatable, Sendable {
    public let analysisLookbackMilliseconds: UInt64
    public let maximumTurnMilliseconds: UInt64
    public let rearmMilliseconds: UInt64

    public init(
        analysisLookbackMilliseconds: UInt64 = 260,
        maximumTurnMilliseconds: UInt64 = 20_000,
        rearmMilliseconds: UInt64 = 750
    ) {
        precondition(analysisLookbackMilliseconds <= 2_000)
        precondition(maximumTurnMilliseconds >= 1_000)
        precondition(rearmMilliseconds <= 10_000)
        self.analysisLookbackMilliseconds = analysisLookbackMilliseconds
        self.maximumTurnMilliseconds = maximumTurnMilliseconds
        self.rearmMilliseconds = rearmMilliseconds
    }
}

public struct SpeechTurnStart: Equatable, Sendable {
    public let speechStartedAtNS: UInt64
    public let wake: HumanInteractionWakeRequest
}

public struct SpeechTurnFinish: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case voiceOffset = "voice_offset"
        case maximumDuration = "maximum_duration"
    }

    public let speechStartedAtNS: UInt64
    public let speechEndedAtNS: UInt64
    public let wake: HumanInteractionWakeRequest
    public let reason: Reason
}

public enum SpeechTurnTransition: Equatable, Sendable {
    case started(SpeechTurnStart)
    case finished(SpeechTurnFinish)
}

/// Converts an authorized C3 wake and the local VAD state into one bounded
/// utterance. Audio ownership remains in the local transport; this state
/// machine contains timestamps and evidence references only.
public struct SpeechTurnSegmenter: Sendable {
    private struct ActiveTurn: Sendable {
        let speechStartedAtNS: UInt64
        let wake: HumanInteractionWakeRequest
    }

    public let configuration: SpeechTurnSegmentationConfiguration
    private var active: ActiveTurn?
    private var rearmAtNS: UInt64 = 0

    public init(configuration: SpeechTurnSegmentationConfiguration = .init()) {
        self.configuration = configuration
    }

    public var isActive: Bool { active != nil }

    public mutating func observe(
        voiceActive: Bool,
        at monotonicNS: UInt64,
        authorizedWake: HumanInteractionWakeRequest? = nil
    ) -> SpeechTurnTransition? {
        if let active {
            let maximumNS = configuration.maximumTurnMilliseconds * 1_000_000
            if monotonicNS >= active.speechStartedAtNS,
               monotonicNS - active.speechStartedAtNS >= maximumNS {
                return finish(active, at: monotonicNS, reason: .maximumDuration)
            }
            guard !voiceActive else { return nil }
            return finish(active, at: monotonicNS, reason: .voiceOffset)
        }

        guard voiceActive,
              monotonicNS >= rearmAtNS,
              let authorizedWake else { return nil }
        let lookbackNS = configuration.analysisLookbackMilliseconds * 1_000_000
        let speechStartedAtNS = monotonicNS >= lookbackNS ? monotonicNS - lookbackNS : 0
        let start = SpeechTurnStart(
            speechStartedAtNS: speechStartedAtNS,
            wake: authorizedWake
        )
        active = ActiveTurn(
            speechStartedAtNS: speechStartedAtNS,
            wake: authorizedWake
        )
        return .started(start)
    }

    public mutating func reset(at monotonicNS: UInt64) {
        active = nil
        rearmAtNS = monotonicNS + configuration.rearmMilliseconds * 1_000_000
    }

    private mutating func finish(
        _ turn: ActiveTurn,
        at monotonicNS: UInt64,
        reason: SpeechTurnFinish.Reason
    ) -> SpeechTurnTransition {
        active = nil
        rearmAtNS = monotonicNS + configuration.rearmMilliseconds * 1_000_000
        return .finished(SpeechTurnFinish(
            speechStartedAtNS: turn.speechStartedAtNS,
            speechEndedAtNS: monotonicNS,
            wake: turn.wake,
            reason: reason
        ))
    }
}
