import Foundation

public enum L1AuxiliaryAttentionHint: String, Codable, CaseIterable, Sendable {
    case person
    case object
    case soundSource = "sound_source"
    case explore
    case none
}

public enum L1AuxiliarySituation: String, Codable, CaseIterable, Sendable {
    case socialBid = "social_bid"
    case objectPresentation = "object_presentation"
    case sceneTransition = "scene_transition"
    case ambient
    case uncertain
}

public enum L1AuxiliaryWakeReason: String, Codable, CaseIterable, Sendable {
    case directSocialBid = "direct_social_bid"
    case presentedObject = "presented_object"
    case unexpectedChange = "unexpected_change"
    case ambiguity
    /// A time-integrated situation estimate, produced locally from multiple
    /// advisory cues rather than supplied by the VLM for one frame.
    case temporalContext = "temporal_context"
    case none
}

public enum L1AuxiliaryBodyLanguage: String, Codable, CaseIterable, Sendable {
    case open
    case closed
    case turnedAway = "turned_away"
    case leaningIn = "leaning_in"
    case none
}

public enum L1AuxiliaryGesture: String, Codable, CaseIterable, Sendable {
    case waving
    case pointing
    case nodding
    case none
}

public enum L1AuxiliaryApproach: String, Codable, CaseIterable, Sendable {
    case approaching
    case stationary
    case leaving
    case none
}

/// An advisory interpretation of the current scene. It is context for L1,
/// never a command to L0: engage for a person socially addressing the camera,
/// orient for a non-person object/scene change, observe for a mild ambient
/// change, none for a quiet static scene.
public enum L1AuxiliaryReaction: String, Codable, CaseIterable, Sendable {
    case engage
    case orient
    case observe
    case none
}

/// Scalar context accompanying one in-memory L1 auxiliary keyframe. It deliberately
/// excludes pixels; the transport owns the ephemeral image payload.
public struct L1AuxiliaryFrameContext: Codable, Equatable, Sendable {
    public let captureNS: UInt64
    public let trigger: String
    public let surprise: Double
    public let informationGain: Double
    public let presenceProbability: Double
    public let voiceProbability: Double
    public let targetKind: AttentionTargetKind?
    /// Opaque scene identity of the visual hypothesis that caused this frame.
    public let targetID: String?
    public let targetLabel: String?
    public let targetProbability: Double
    public let targetStatus: TargetStatus

    public init(captureNS: UInt64, trigger: String, belief: BeliefSnapshot) {
        self.captureNS = captureNS
        self.trigger = trigger
        surprise = belief.surprise
        informationGain = belief.informationGain
        presenceProbability = belief.presenceProbability
        voiceProbability = belief.voiceProbability
        targetKind = belief.target?.kind
        targetID = belief.target?.id
        targetLabel = belief.target?.label
        targetProbability = belief.target?.posteriorProbability ?? 0
        targetStatus = belief.targetStatus
    }

    public init(
        captureNS: UInt64,
        trigger: String,
        surprise: Double,
        informationGain: Double,
        presenceProbability: Double,
        voiceProbability: Double,
        targetKind: AttentionTargetKind?,
        targetID: String? = nil,
        targetLabel: String?,
        targetProbability: Double,
        targetStatus: TargetStatus
    ) {
        self.captureNS = captureNS
        self.trigger = trigger
        self.surprise = surprise
        self.informationGain = informationGain
        self.presenceProbability = presenceProbability
        self.voiceProbability = voiceProbability
        self.targetKind = targetKind
        self.targetID = targetID
        self.targetLabel = targetLabel
        self.targetProbability = targetProbability
        self.targetStatus = targetStatus
    }

    public var targetSignature: String {
        "\(targetStatus.rawValue)|\(targetKind?.rawValue ?? "none")|\(targetLabel ?? "none")"
    }
}

public struct L1AuxiliarySemanticCue: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let captureNS: UInt64
    public let completedNS: UInt64
    public let source: String
    public let summary: String
    public let novelty: Double
    public let socialPresence: Double
    /// Opaque scene identity associated with the encoded frame, if available.
    public let targetID: String?
    public let attentionHint: L1AuxiliaryAttentionHint
    public let situation: L1AuxiliarySituation
    public let wakeReason: L1AuxiliaryWakeReason
    public let wakeScore: Double
    public let confidence: Double
    public let eyeContact: Double
    public let engagement: Double
    public let bodyLanguage: L1AuxiliaryBodyLanguage
    public let gesture: L1AuxiliaryGesture
    public let approach: L1AuxiliaryApproach
    public let reaction: L1AuxiliaryReaction
    public let conversationValue: Double
    public let objectLabel: String
    public let inferenceMS: Double

    public init(
        requestID: UInt64,
        captureNS: UInt64,
        completedNS: UInt64,
        source: String,
        summary: String,
        novelty: Double,
        socialPresence: Double,
        targetID: String? = nil,
        attentionHint: L1AuxiliaryAttentionHint,
        situation: L1AuxiliarySituation,
        wakeReason: L1AuxiliaryWakeReason,
        wakeScore: Double,
        confidence: Double,
        eyeContact: Double = 0,
        engagement: Double = 0,
        bodyLanguage: L1AuxiliaryBodyLanguage = .none,
        gesture: L1AuxiliaryGesture = .none,
        approach: L1AuxiliaryApproach = .none,
        reaction: L1AuxiliaryReaction = .none,
        conversationValue: Double = 0,
        objectLabel: String = "",
        inferenceMS: Double
    ) {
        self.requestID = requestID
        self.captureNS = captureNS
        self.completedNS = completedNS
        self.source = source
        self.summary = String(summary.prefix(160))
        self.novelty = min(max(novelty, 0), 1)
        self.socialPresence = min(max(socialPresence, 0), 1)
        self.targetID = targetID
        self.attentionHint = attentionHint
        self.situation = situation
        self.wakeReason = wakeReason
        self.wakeScore = min(max(wakeScore, 0), 1)
        self.confidence = min(max(confidence, 0), 1)
        self.eyeContact = min(max(eyeContact, 0), 1)
        self.engagement = min(max(engagement, 0), 1)
        self.bodyLanguage = bodyLanguage
        self.gesture = gesture
        self.approach = approach
        self.reaction = reaction
        self.conversationValue = min(max(conversationValue, 0), 1)
        self.objectLabel = String(objectLabel.prefix(60))
        self.inferenceMS = max(0, inferenceMS)
    }
}

/// Scalar proposal from the local visual helper to the primary L1 stream. It
/// has no independent motor, dialogue, memory, or task-execution authority.
public struct L1AuxiliarySemanticInterrupt: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let captureNS: UInt64
    public let completedNS: UInt64
    public let situation: L1AuxiliarySituation
    public let reason: L1AuxiliaryWakeReason
    public let score: Double
    public let confidence: Double
    public let evidence: String
}

public struct L1AuxiliarySemanticInterruptGate: Sendable {
    private let minimumWakeScore: Double
    private let minimumConfidence: Double
    private let repeatIntervalNS: UInt64
    private var lastSignature: String?
    private var lastEmittedNS: UInt64?

    public init(
        minimumWakeScore: Double = 0.65,
        minimumConfidence: Double = 0.55,
        repeatIntervalMilliseconds: UInt64 = 5_000
    ) {
        self.minimumWakeScore = min(max(minimumWakeScore, 0), 1)
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        repeatIntervalNS = repeatIntervalMilliseconds * 1_000_000
    }

    public mutating func recommend(_ cue: L1AuxiliarySemanticCue) -> L1AuxiliarySemanticInterrupt? {
        guard cue.wakeScore >= minimumWakeScore,
              cue.confidence >= minimumConfidence,
              isConsistent(situation: cue.situation, reason: cue.wakeReason) else {
            return nil
        }
        let signature = "\(cue.situation.rawValue)|\(cue.wakeReason.rawValue)"
        if signature == lastSignature,
           let lastEmittedNS,
           cue.completedNS >= lastEmittedNS,
           cue.completedNS - lastEmittedNS < repeatIntervalNS {
            return nil
        }
        lastSignature = signature
        lastEmittedNS = cue.completedNS
        return L1AuxiliarySemanticInterrupt(
            requestID: cue.requestID,
            captureNS: cue.captureNS,
            completedNS: cue.completedNS,
            situation: cue.situation,
            reason: cue.wakeReason,
            score: cue.wakeScore,
            confidence: cue.confidence,
            evidence: cue.summary
        )
    }

    private func isConsistent(situation: L1AuxiliarySituation, reason: L1AuxiliaryWakeReason) -> Bool {
        switch (situation, reason) {
        case (.socialBid, .directSocialBid),
             (.objectPresentation, .presentedObject),
             (.sceneTransition, .unexpectedChange),
             (.uncertain, .ambiguity):
            return true
        default:
            return false
        }
    }
}

/// The coarse interpretation whose persistence may be worth a conscious L1
/// reassessment. This is intentionally about context, not a motor target.
public enum L1AuxiliaryTemporalTheme: String, Codable, CaseIterable, Sendable {
    case socialAvailability = "social_availability"
    case sceneRelevance = "scene_relevance"
    case unresolvedChange = "unresolved_change"
}

/// Integrates a sequence of local semantic cues into a bounded, one-shot
/// request for L1 to reconsider the situation. It has no command path: the
/// returned interrupt remains advisory evidence for the primary L1 stream.
///
/// A stable context needs both elapsed time and repeated evidence. The latent
/// probability decays continuously between cues, resets when its coarse theme
/// changes or sampling has a long gap, and uses hysteresis after emission so a
/// static scene cannot repeatedly wake L1.
public struct L1AuxiliaryTemporalSituationGate: Sendable {
    private struct Observation: Sendable {
        let theme: L1AuxiliaryTemporalTheme
        let probability: Double
        let confidence: Double
    }

    private struct State: Sendable {
        let theme: L1AuxiliaryTemporalTheme
        let startedNS: UInt64
        var lastNS: UInt64
        var posterior: Double
        var confidence: Double
        var samples: Int
        var latched: Bool
    }

    private let minimumPosterior: Double
    private let minimumConfidence: Double
    private let minimumEvidenceNS: UInt64
    private let integrationTimeConstantNS: UInt64
    private let maximumGapNS: UInt64
    private let releasePosterior: Double
    private let minimumObservation: Double
    private var state: State?

    public init(
        minimumPosterior: Double = 0.62,
        minimumConfidence: Double = 0.55,
        minimumEvidenceMilliseconds: UInt64 = 6_000,
        integrationTimeConstantMilliseconds: UInt64 = 6_000,
        maximumGapMilliseconds: UInt64 = 12_000,
        releasePosterior: Double = 0.35,
        minimumObservation: Double = 0.20
    ) {
        self.minimumPosterior = min(max(minimumPosterior, 0), 1)
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        minimumEvidenceNS = max(minimumEvidenceMilliseconds, 1) * 1_000_000
        integrationTimeConstantNS = max(integrationTimeConstantMilliseconds, 1) * 1_000_000
        maximumGapNS = max(maximumGapMilliseconds, minimumEvidenceMilliseconds) * 1_000_000
        self.releasePosterior = min(max(releasePosterior, 0), self.minimumPosterior)
        self.minimumObservation = min(max(minimumObservation, 0), 1)
    }

    /// Adds one completed local cue. A returned value is a request to reason,
    /// never permission to move, speak, or mutate memory.
    public mutating func recommend(_ cue: L1AuxiliarySemanticCue) -> L1AuxiliarySemanticInterrupt? {
        let now = cue.completedNS
        guard now > 0 else { return nil }
        guard let observation = observation(from: cue) else {
            decayWithoutObservation(at: now)
            return nil
        }

        guard var state,
              now > state.lastNS,
              state.theme == observation.theme,
              now - state.lastNS <= maximumGapNS else {
            self.state = State(
                theme: observation.theme,
                startedNS: now,
                lastNS: now,
                posterior: 0,
                confidence: observation.confidence,
                samples: 1,
                latched: false
            )
            return nil
        }

        let elapsedNS = now - state.lastNS
        let retention = exp(-Double(elapsedNS) / Double(integrationTimeConstantNS))
        state.posterior = state.posterior * retention + observation.probability * (1 - retention)
        state.confidence = state.confidence * retention + observation.confidence * (1 - retention)
        state.lastNS = now
        state.samples += 1

        if state.latched {
            if state.posterior <= releasePosterior {
                state.latched = false
            }
            self.state = state
            return nil
        }

        let durationNS = now - state.startedNS
        guard durationNS >= minimumEvidenceNS,
              state.samples >= 2,
              state.posterior >= minimumPosterior,
              state.confidence >= minimumConfidence else {
            self.state = state
            return nil
        }

        state.latched = true
        self.state = state
        let durationMS = durationNS / 1_000_000
        let posterior = String(format: "%.2f", state.posterior)
        let evidence = String(
            "temporal_theme=\(state.theme.rawValue); duration_ms=\(durationMS); posterior=\(posterior); \(cue.summary)".prefix(160)
        )
        return L1AuxiliarySemanticInterrupt(
            requestID: cue.requestID,
            captureNS: cue.captureNS,
            completedNS: now,
            situation: cue.situation,
            reason: .temporalContext,
            score: state.posterior,
            confidence: state.confidence,
            evidence: evidence
        )
    }

    /// A high-confidence one-frame semantic interrupt already received an L1
    /// cycle. Latch its current theme so the temporal path cannot immediately
    /// duplicate that same episode.
    public mutating func markHandled(_ cue: L1AuxiliarySemanticCue) {
        guard let observation = observation(from: cue), cue.completedNS > 0 else {
            return
        }
        state = State(
            theme: observation.theme,
            startedNS: cue.completedNS,
            lastNS: cue.completedNS,
            posterior: observation.probability,
            confidence: observation.confidence,
            samples: 1,
            latched: true
        )
    }

    private mutating func decayWithoutObservation(at now: UInt64) {
        guard var state, now > state.lastNS else { return }
        let elapsedNS = now - state.lastNS
        if elapsedNS > maximumGapNS {
            self.state = nil
            return
        }
        let retention = exp(-Double(elapsedNS) / Double(integrationTimeConstantNS))
        state.posterior *= retention
        state.lastNS = now
        if state.latched, state.posterior <= releasePosterior {
            state.latched = false
        }
        self.state = state
    }

    private func observation(from cue: L1AuxiliarySemanticCue) -> Observation? {
        let approachSignal: Double = cue.approach == .approaching ? 0.85 : 0
        let gestureSignal: Double = cue.gesture == .none ? 0 : 0.90
        let socialAvailability = max(
            cue.eyeContact,
            cue.engagement * 0.80,
            approachSignal,
            gestureSignal
        )
        let social = cue.socialPresence * socialAvailability

        let transition = cue.situation == .sceneTransition
            ? max(cue.novelty, 0.40)
            : 0
        let objectRelevance = cue.conversationValue * (0.40 + 0.60 * cue.novelty)
        let scene = max(transition, objectRelevance)

        let uncertainty = cue.situation == .uncertain
            ? cue.novelty * (1 - cue.confidence)
            : 0

        let ranked: [(L1AuxiliaryTemporalTheme, Double)] = [
            (.socialAvailability, social),
            (.sceneRelevance, scene),
            (.unresolvedChange, uncertainty),
        ]
        guard let strongest = ranked.max(by: { $0.1 < $1.1 }),
              strongest.1 >= minimumObservation else {
            return nil
        }
        return Observation(
            theme: strongest.0,
            probability: min(max(strongest.1, 0), 1),
            confidence: cue.confidence
        )
    }
}

/// Event-driven admission for L1's local semantic helper. A changed target or
/// high-surprise frame may run at most once per second; an unchanged scene gets
/// a sparse five-second refresh. This gate never delays the L0 capture thread.
public struct L1AuxiliarySemanticAdmissionGate: Sendable {
    private let eventIntervalNS: UInt64
    private let refreshIntervalNS: UInt64
    private let salienceThreshold: Double
    private var lastAcceptedNS: UInt64?
    private var lastTargetSignature: String?

    public init(
        eventIntervalMilliseconds: UInt64 = 1_000,
        refreshIntervalMilliseconds: UInt64 = 5_000,
        salienceThreshold: Double = 0.65
    ) {
        eventIntervalNS = eventIntervalMilliseconds * 1_000_000
        refreshIntervalNS = refreshIntervalMilliseconds * 1_000_000
        self.salienceThreshold = min(max(salienceThreshold, 0), 1)
    }

    public mutating func admit(_ context: L1AuxiliaryFrameContext) -> Bool {
        guard let lastAcceptedNS else {
            accept(context)
            return true
        }
        guard context.captureNS >= lastAcceptedNS else { return false }
        let elapsed = context.captureNS - lastAcceptedNS
        let targetChanged = context.targetSignature != lastTargetSignature
        let salient = max(context.surprise, context.informationGain) >= salienceThreshold
        guard elapsed >= refreshIntervalNS || (elapsed >= eventIntervalNS && (targetChanged || salient)) else {
            return false
        }
        accept(context)
        return true
    }

    private mutating func accept(_ context: L1AuxiliaryFrameContext) {
        lastAcceptedNS = context.captureNS
        lastTargetSignature = context.targetSignature
    }
}
