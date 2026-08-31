import Foundation

public enum AudioVisualSpeakerClass: String, Codable, Equatable, Sendable {
    case likelySpeaker = "likely_speaker"
    case ambiguous
    case likelyBackground = "likely_background"
}

public struct AudioVisualSpeakerEvidence: Equatable, Sendable {
    public let faceVisible: Bool
    public let directGaze: Bool
    public let mouthMotion: Double?
    public let mouthSampleCount: Int
    public let directionMatchesFace: Bool?
    public let voiceConfidence: Double

    public init(
        faceVisible: Bool,
        directGaze: Bool,
        mouthMotion: Double?,
        mouthSampleCount: Int,
        directionMatchesFace: Bool?,
        voiceConfidence: Double
    ) {
        self.faceVisible = faceVisible
        self.directGaze = directGaze
        self.mouthMotion = mouthMotion.map { min(max($0, 0), 1) }
        self.mouthSampleCount = max(0, mouthSampleCount)
        self.directionMatchesFace = directionMatchesFace
        self.voiceConfidence = min(max(voiceConfidence, 0), 1)
    }
}

public struct AudioVisualSpeakerAssessment: Equatable, Sendable {
    public let classification: AudioVisualSpeakerClass
    public let probability: Double

    public init(classification: AudioVisualSpeakerClass, probability: Double) {
        self.classification = classification
        self.probability = min(max(probability, 0), 1)
    }

    /// Ambiguous evidence must not erase ordinary voice interaction. Only
    /// strong contradictory audiovisual evidence rejects a participant turn.
    public var admitsAudio: Bool { classification != .likelyBackground }
}

public enum AudioVisualSpeakerAttribution {
    public static func assess(_ evidence: AudioVisualSpeakerEvidence) -> AudioVisualSpeakerAssessment {
        guard evidence.faceVisible else {
            return .init(classification: .ambiguous, probability: 0.45)
        }
        var probability = 0.10
        if evidence.directGaze { probability += 0.35 }
        probability += evidence.voiceConfidence * 0.15
        if let mouthMotion = evidence.mouthMotion, evidence.mouthSampleCount >= 3 {
            probability += mouthMotion * 0.40
            probability -= (1 - mouthMotion) * 0.25
        }
        if let directionMatchesFace = evidence.directionMatchesFace {
            probability += directionMatchesFace ? 0.25 : -0.45
        }
        probability = min(max(probability, 0), 1)
        let classification: AudioVisualSpeakerClass
        let independentSpeakerCue = evidence.directionMatchesFace == true
            || (evidence.mouthSampleCount >= 3 && (evidence.mouthMotion ?? 0) >= 0.18)
        if probability >= 0.58, independentSpeakerCue {
            classification = .likelySpeaker
        } else if probability <= 0.38,
                  evidence.directionMatchesFace == false {
            // Lip motion observed before the acoustic onset is not proof that
            // the upcoming sound belongs to somebody else. A spatial mismatch
            // is the only negative cue strong enough to reject immediately;
            // missing or one-sided evidence remains ambiguous and fail-open.
            classification = .likelyBackground
        } else {
            classification = .ambiguous
        }
        return .init(classification: classification, probability: probability)
    }
}

public struct TimestampedVisualGazeEvidence: Equatable, Sendable {
    public let state: VisualGazeEvidence
    public let observedNS: UInt64

    public init(state: VisualGazeEvidence, observedNS: UInt64) {
        self.state = state
        self.observedNS = observedNS
    }
}

/// Resolves the last meaningful gaze observation at acoustic onset. Missing
/// landmarks are absence of evidence, not evidence that contact ended; an
/// explicit averted observation still supersedes an earlier direct one.
public enum LiveVoiceOnsetGazeResolver {
    public static func resolve(
        _ samples: [TimestampedVisualGazeEvidence],
        onsetNS: UInt64,
        maximumAgeMilliseconds: UInt64 = 250
    ) -> TimestampedVisualGazeEvidence? {
        precondition(maximumAgeMilliseconds > 0)
        precondition(maximumAgeMilliseconds <= UInt64.max / 1_000_000)
        let maximumAgeNS = maximumAgeMilliseconds * 1_000_000
        return samples
            .filter {
                $0.state != .unavailable
                    && onsetNS >= $0.observedNS
                    && onsetNS - $0.observedNS <= maximumAgeNS
            }
            .max { $0.observedNS < $1.observedNS }
    }
}

public enum AudioVisualEpisodeEvidence {
    public static func resolvedOnset(
        classifiedWindowStartNS: UInt64,
        classifiedWindowEndNS: UInt64,
        acousticOnsetNS: UInt64?,
        earliestAllowedNS: UInt64? = nil
    ) -> UInt64 {
        let lowerBound = earliestAllowedNS ?? classifiedWindowStartNS
        guard let acousticOnsetNS,
              acousticOnsetNS >= lowerBound,
              acousticOnsetNS <= classifiedWindowEndNS else {
            return max(classifiedWindowStartNS, lowerBound)
        }
        return acousticOnsetNS
    }

    public static func belongsToCurrentEpisode(
        observedNS: UInt64,
        onsetNS: UInt64,
        nowNS: UInt64,
        maximumAgeNS: UInt64
    ) -> Bool {
        observedNS >= onsetNS
            && observedNS <= nowNS
            && nowNS - observedNS <= maximumAgeNS
    }

    public static func mouthMotion(
        baseline: Double?,
        postOnsetApertures: [Double]
    ) -> Double? {
        guard postOnsetApertures.count >= 2 else { return nil }
        let values = [baseline].compactMap { $0 } + postOnsetApertures
        guard values.count >= 3,
              let minimum = values.min(),
              let maximum = values.max() else { return nil }
        return min(max((maximum - minimum) / 0.08, 0), 1)
    }
}

public enum LiveVoiceSpeakerEpisodeState: String, Equatable, Sendable {
    case idle
    case pending
    case confirmed
    case rejected
}

/// Temporal speech evidence required before a new participant episode can be
/// promoted into a Live Voice session. A strong window may qualify speech
/// immediately; the episode gate still requires matching visual contact and
/// independent speaker evidence before it authorizes a session.
public struct LiveVoiceOpeningSpeechConfiguration: Equatable, Sendable {
    public let strongConfidence: Double
    public let supportingConfidence: Double
    public let requiredStrongWindows: Int
    public let requiredSupportingWindows: Int
    public let maximumWindowGapMilliseconds: UInt64

    public init(
        strongConfidence: Double = 0.80,
        supportingConfidence: Double = 0.68,
        requiredStrongWindows: Int = 1,
        requiredSupportingWindows: Int = 3,
        maximumWindowGapMilliseconds: UInt64 = 650
    ) {
        precondition((0...1).contains(strongConfidence))
        precondition((0...1).contains(supportingConfidence))
        precondition(supportingConfidence <= strongConfidence)
        precondition(requiredStrongWindows >= 1)
        precondition(requiredSupportingWindows >= requiredStrongWindows)
        precondition(maximumWindowGapMilliseconds > 0)
        precondition(maximumWindowGapMilliseconds <= UInt64.max / 1_000_000)
        self.strongConfidence = strongConfidence
        self.supportingConfidence = supportingConfidence
        self.requiredStrongWindows = requiredStrongWindows
        self.requiredSupportingWindows = requiredSupportingWindows
        self.maximumWindowGapMilliseconds = maximumWindowGapMilliseconds
    }
}

public struct LiveVoiceOpeningSpeechEvidence: Equatable, Sendable {
    public let qualified: Bool
    public let strongWindowCount: Int
    public let supportingWindowCount: Int
}

public struct LiveVoiceOpeningSpeechAccumulator: Sendable {
    public let configuration: LiveVoiceOpeningSpeechConfiguration

    private var strongWindowCount = 0
    private var supportingWindowCount = 0
    private var lastWindowNS: UInt64?
    private var qualified = false

    public init(configuration: LiveVoiceOpeningSpeechConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func observe(
        active: Bool,
        confidence rawConfidence: Double,
        at monotonicNS: UInt64
    ) -> LiveVoiceOpeningSpeechEvidence {
        guard active else {
            reset()
            return snapshot
        }
        guard !qualified else { return snapshot }

        let confidence = min(max(rawConfidence, 0), 1)
        let continuesSequence: Bool
        if let lastWindowNS,
           monotonicNS > lastWindowNS,
           monotonicNS - lastWindowNS <= configuration.maximumWindowGapMilliseconds * 1_000_000 {
            continuesSequence = true
        } else {
            continuesSequence = false
        }
        if !continuesSequence {
            strongWindowCount = 0
            supportingWindowCount = 0
        }

        guard confidence >= configuration.supportingConfidence else {
            strongWindowCount = 0
            supportingWindowCount = 0
            lastWindowNS = monotonicNS
            return snapshot
        }

        supportingWindowCount += 1
        if confidence >= configuration.strongConfidence {
            strongWindowCount += 1
        } else {
            strongWindowCount = 0
        }
        lastWindowNS = monotonicNS
        qualified = strongWindowCount >= configuration.requiredStrongWindows
            || supportingWindowCount >= configuration.requiredSupportingWindows
        return snapshot
    }

    public mutating func reset() {
        strongWindowCount = 0
        supportingWindowCount = 0
        lastWindowNS = nil
        qualified = false
    }

    public var snapshot: LiveVoiceOpeningSpeechEvidence {
        .init(
            qualified: qualified,
            strongWindowCount: strongWindowCount,
            supportingWindowCount: supportingWindowCount
        )
    }
}

public struct LiveVoiceSpeakerEpisodeObservation: Equatable, Sendable {
    public let state: LiveVoiceSpeakerEpisodeState
    public let didTransition: Bool
    public let directContactObserved: Bool
    public let speakerEvidenceObserved: Bool
    public let speechEvidence: LiveVoiceOpeningSpeechEvidence
    public let maximumVoiceConfidence: Double
    public let endedState: LiveVoiceSpeakerEpisodeState?
}

/// Joins onset-time visual contact with independent speaker evidence for one
/// continuously tracked face. The visual result may be delivered later, but
/// its capture must precede the acoustic onset; a face switch, contradiction,
/// or expired episode prevents evidence from different people or moments from
/// being combined.
public struct LiveVoiceSpeakerEpisodeGate: Sendable {
    private let maximumResolutionNS: UInt64
    private let maximumEvidenceSkewNS: UInt64
    private let maximumContactLeadNS: UInt64
    private var episodeActive = false
    private var state: LiveVoiceSpeakerEpisodeState = .idle
    private var onsetNS: UInt64 = 0
    private var targetID: String?
    private var directContactObserved = false
    private var speakerEvidenceObserved = false
    private var lastDirectContactNS: UInt64?
    private var lastContactContradictionNS: UInt64?
    private var lastSpeakerEvidenceNS: UInt64?
    private var confirmedAtNS: UInt64?
    private var maximumVoiceConfidence = 0.0
    private var openingSpeechEvidence: LiveVoiceOpeningSpeechAccumulator

    public init(
        maximumResolutionMilliseconds: UInt64 = 3_000,
        maximumEvidenceSkewMilliseconds: UInt64 = 750,
        maximumContactLeadMilliseconds: UInt64 = 250,
        openingSpeechConfiguration: LiveVoiceOpeningSpeechConfiguration = .init()
    ) {
        precondition(maximumResolutionMilliseconds > 0)
        precondition(maximumResolutionMilliseconds <= UInt64.max / 1_000_000)
        precondition(maximumEvidenceSkewMilliseconds > 0)
        precondition(maximumEvidenceSkewMilliseconds <= UInt64.max / 1_000_000)
        precondition(maximumContactLeadMilliseconds > 0)
        precondition(maximumContactLeadMilliseconds <= UInt64.max / 1_000_000)
        maximumResolutionNS = maximumResolutionMilliseconds * 1_000_000
        maximumEvidenceSkewNS = maximumEvidenceSkewMilliseconds * 1_000_000
        maximumContactLeadNS = maximumContactLeadMilliseconds * 1_000_000
        openingSpeechEvidence = LiveVoiceOpeningSpeechAccumulator(
            configuration: openingSpeechConfiguration
        )
    }

    public mutating func observe(
        active: Bool,
        trackedFaceID: String?,
        evidence: AudioVisualSpeakerEvidence,
        assessment: AudioVisualSpeakerAssessment,
        directContactObservedNS: UInt64? = nil,
        directContactContradictedNS: UInt64? = nil,
        speakerEvidenceObservedNS: UInt64? = nil,
        voiceWindowObservedNS: UInt64? = nil,
        episodeOnsetNS: UInt64? = nil,
        at monotonicNS: UInt64
    ) -> LiveVoiceSpeakerEpisodeObservation {
        guard active else {
            let endedState = state == .idle ? nil : state
            let transitioned = state != .idle || episodeActive
            episodeActive = false
            state = .idle
            onsetNS = 0
            targetID = nil
            directContactObserved = false
            speakerEvidenceObserved = false
            lastDirectContactNS = nil
            lastContactContradictionNS = nil
            lastSpeakerEvidenceNS = nil
            confirmedAtNS = nil
            maximumVoiceConfidence = 0
            openingSpeechEvidence.reset()
            return observation(didTransition: transitioned, endedState: endedState)
        }

        maximumVoiceConfidence = max(maximumVoiceConfidence, evidence.voiceConfidence)
        let voiceEvidenceNS = voiceWindowObservedNS.flatMap {
            $0 <= monotonicNS ? $0 : nil
        } ?? monotonicNS
        _ = openingSpeechEvidence.observe(
            active: true,
            confidence: evidence.voiceConfidence,
            at: voiceEvidenceNS
        )
        if !episodeActive {
            episodeActive = true
            onsetNS = episodeOnsetNS ?? monotonicNS
            targetID = trackedFaceID
            guard targetID != nil else {
                state = .rejected
                return observation(didTransition: true)
            }
            accumulate(
                evidence: evidence,
                assessment: assessment,
                directContactObservedNS: directContactObservedNS,
                directContactContradictedNS: directContactContradictedNS,
                speakerEvidenceObservedNS: speakerEvidenceObservedNS,
                at: monotonicNS
            )
            state = resolvedState(
                assessment: assessment,
                at: monotonicNS
            )
            if state == .confirmed { confirmedAtNS = monotonicNS }
            return observation(didTransition: true)
        }

        if state == .confirmed {
            guard trackedFaceID == targetID,
                  assessment.classification != .likelyBackground else {
                state = .rejected
                return observation(didTransition: true)
            }
            if invalidatesConfirmedContact(directContactContradictedNS) {
                state = .rejected
                directContactObserved = false
                lastDirectContactNS = nil
                return observation(didTransition: true)
            }
            return observation(didTransition: false)
        }
        guard state == .pending else { return observation(didTransition: false) }
        guard trackedFaceID == targetID else {
            state = .rejected
            return observation(didTransition: true)
        }
        accumulate(
            evidence: evidence,
            assessment: assessment,
            directContactObservedNS: directContactObservedNS,
            directContactContradictedNS: directContactContradictedNS,
            speakerEvidenceObservedNS: speakerEvidenceObservedNS,
            at: monotonicNS
        )
        let resolved = resolvedState(
            assessment: assessment,
            at: monotonicNS
        )
        if resolved != .pending {
            state = resolved
            if resolved == .confirmed { confirmedAtNS = monotonicNS }
            return observation(didTransition: true)
        }
        return observation(didTransition: false)
    }

    /// Applies a gaze result as soon as the visual worker publishes it. A
    /// result captured before confirmation is part of that confirmation even
    /// when its asynchronous callback arrives slightly later. Looking away
    /// after a valid opening does not revoke the established conversation.
    public mutating func observeGaze(
        _ gaze: VisualGazeEvidence,
        trackedFaceID: String,
        observedNS: UInt64,
        at monotonicNS: UInt64
    ) -> LiveVoiceSpeakerEpisodeObservation {
        guard episodeActive,
              trackedFaceID == targetID,
              observedNS <= monotonicNS else {
            return observation(didTransition: false)
        }
        if gaze == .direct,
           state == .pending,
           isValidOnsetContact(observedNS),
           lastContactContradictionNS.map({ observedNS > $0 }) ?? true {
            directContactObserved = true
            lastDirectContactNS = observedNS
            let resolved = resolvedAccumulatedState(at: monotonicNS)
            if resolved == .confirmed {
                state = .confirmed
                confirmedAtNS = monotonicNS
                return observation(didTransition: true)
            }
            return observation(didTransition: false)
        }
        guard gaze == .averted else {
            return observation(didTransition: false)
        }
        if lastContactContradictionNS.map({ observedNS > $0 }) ?? true {
            lastContactContradictionNS = observedNS
        }
        if state == .confirmed {
            guard invalidatesConfirmedContact(observedNS) else {
                return observation(didTransition: false)
            }
            state = .rejected
            directContactObserved = false
            lastDirectContactNS = nil
            return observation(didTransition: true)
        }
        guard state == .pending,
              let lastDirectContactNS,
              observedNS >= lastDirectContactNS else {
            return observation(didTransition: false)
        }
        directContactObserved = false
        self.lastDirectContactNS = nil
        return observation(didTransition: false)
    }

    private func resolvedState(
        assessment: AudioVisualSpeakerAssessment,
        at monotonicNS: UInt64
    ) -> LiveVoiceSpeakerEpisodeState {
        if assessment.classification == .likelyBackground {
            return .rejected
        }
        return resolvedAccumulatedState(at: monotonicNS)
    }

    private func resolvedAccumulatedState(
        at monotonicNS: UInt64
    ) -> LiveVoiceSpeakerEpisodeState {
        if monotonicNS >= onsetNS,
           monotonicNS - onsetNS >= maximumResolutionNS {
            return .rejected
        }
        guard let lastDirectContactNS,
              let lastSpeakerEvidenceNS,
              openingSpeechEvidence.snapshot.qualified else {
            return .pending
        }
        let skew = lastDirectContactNS >= lastSpeakerEvidenceNS
            ? lastDirectContactNS - lastSpeakerEvidenceNS
            : lastSpeakerEvidenceNS - lastDirectContactNS
        return skew <= maximumEvidenceSkewNS ? .confirmed : .pending
    }

    private mutating func accumulate(
        evidence: AudioVisualSpeakerEvidence,
        assessment: AudioVisualSpeakerAssessment,
        directContactObservedNS: UInt64?,
        directContactContradictedNS: UInt64?,
        speakerEvidenceObservedNS: UInt64?,
        at monotonicNS: UInt64
    ) {
        if let contradictedNS = validObservationTimeIfPresent(
            directContactContradictedNS,
            noLaterThan: monotonicNS
        ) {
            if lastContactContradictionNS.map({ contradictedNS > $0 }) ?? true {
                lastContactContradictionNS = contradictedNS
            }
            if lastDirectContactNS.map({ contradictedNS >= $0 }) ?? false {
                directContactObserved = false
                lastDirectContactNS = nil
            }
        }
        if evidence.faceVisible && evidence.directGaze {
            let contactNS = validObservationTime(
                directContactObservedNS,
                fallback: monotonicNS
            )
            if isValidOnsetContact(contactNS),
               lastContactContradictionNS.map({ contactNS > $0 }) ?? true {
                directContactObserved = true
                lastDirectContactNS = contactNS
            }
        }
        if assessment.classification == .likelySpeaker {
            speakerEvidenceObserved = true
            lastSpeakerEvidenceNS = validObservationTime(
                speakerEvidenceObservedNS,
                fallback: monotonicNS
            )
        }
    }

    private func validObservationTime(
        _ observedNS: UInt64?,
        fallback monotonicNS: UInt64
    ) -> UInt64 {
        guard let observedNS, observedNS <= monotonicNS else { return monotonicNS }
        return observedNS
    }

    private func validObservationTimeIfPresent(
        _ observedNS: UInt64?,
        noLaterThan monotonicNS: UInt64
    ) -> UInt64? {
        guard let observedNS, observedNS <= monotonicNS else { return nil }
        return observedNS
    }

    private func invalidatesConfirmedContact(_ contradictedNS: UInt64?) -> Bool {
        guard let contradictedNS,
              let confirmedAtNS,
              contradictedNS <= confirmedAtNS,
              lastDirectContactNS.map({ contradictedNS >= $0 }) ?? true else {
            return false
        }
        return true
    }

    private func isValidOnsetContact(_ observedNS: UInt64) -> Bool {
        onsetNS >= observedNS && onsetNS - observedNS <= maximumContactLeadNS
    }

    private func observation(
        didTransition: Bool,
        endedState: LiveVoiceSpeakerEpisodeState? = nil
    ) -> LiveVoiceSpeakerEpisodeObservation {
        .init(
            state: state,
            didTransition: didTransition,
            directContactObserved: directContactObserved,
            speakerEvidenceObserved: speakerEvidenceObserved,
            speechEvidence: openingSpeechEvidence.snapshot,
            maximumVoiceConfidence: maximumVoiceConfidence,
            endedState: endedState
        )
    }
}
