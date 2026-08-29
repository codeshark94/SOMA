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

public struct LiveVoiceSpeakerEpisodeObservation: Equatable, Sendable {
    public let state: LiveVoiceSpeakerEpisodeState
    public let didTransition: Bool
    public let directContactAtOnset: Bool
    public let maximumVoiceConfidence: Double
    public let endedState: LiveVoiceSpeakerEpisodeState?
}

/// Freezes the visual half of an interaction at acoustic onset, then gives the
/// slower lip-motion and directional evidence a short bounded window to catch
/// up. A gaze acquired after onset can never upgrade ambient sound, and a face
/// switch cannot complete another person's pending turn.
public struct LiveVoiceSpeakerEpisodeGate: Sendable {
    private let maximumResolutionNS: UInt64
    private var episodeActive = false
    private var state: LiveVoiceSpeakerEpisodeState = .idle
    private var onsetNS: UInt64 = 0
    private var targetID: String?
    private var directContactAtOnset = false
    private var maximumVoiceConfidence = 0.0

    public init(maximumResolutionMilliseconds: UInt64 = 750) {
        precondition(maximumResolutionMilliseconds > 0)
        precondition(maximumResolutionMilliseconds <= UInt64.max / 1_000_000)
        maximumResolutionNS = maximumResolutionMilliseconds * 1_000_000
    }

    public mutating func observe(
        active: Bool,
        trackedFaceID: String?,
        evidence: AudioVisualSpeakerEvidence,
        assessment: AudioVisualSpeakerAssessment,
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
            directContactAtOnset = false
            maximumVoiceConfidence = 0
            return observation(didTransition: transitioned, endedState: endedState)
        }

        maximumVoiceConfidence = max(maximumVoiceConfidence, evidence.voiceConfidence)
        if !episodeActive {
            episodeActive = true
            onsetNS = episodeOnsetNS ?? monotonicNS
            targetID = trackedFaceID
            directContactAtOnset = trackedFaceID != nil
                && evidence.faceVisible
                && evidence.directGaze
            if monotonicNS >= onsetNS,
               monotonicNS - onsetNS >= maximumResolutionNS {
                state = .rejected
            } else {
                state = directContactAtOnset ? resolvedState(for: assessment) : .rejected
            }
            return observation(didTransition: true)
        }

        if state == .confirmed {
            guard trackedFaceID == targetID,
                  assessment.classification != .likelyBackground else {
                state = .rejected
                return observation(didTransition: true)
            }
            return observation(didTransition: false)
        }
        guard state == .pending else { return observation(didTransition: false) }
        guard trackedFaceID == targetID else {
            state = .rejected
            return observation(didTransition: true)
        }
        if monotonicNS >= onsetNS,
           monotonicNS - onsetNS >= maximumResolutionNS {
            state = .rejected
            return observation(didTransition: true)
        }
        let resolved = resolvedState(for: assessment)
        if resolved != .pending {
            state = resolved
            return observation(didTransition: true)
        }
        return observation(didTransition: false)
    }

    private func resolvedState(
        for assessment: AudioVisualSpeakerAssessment
    ) -> LiveVoiceSpeakerEpisodeState {
        switch assessment.classification {
        case .likelySpeaker: .confirmed
        case .likelyBackground: .rejected
        case .ambiguous: .pending
        }
    }

    private func observation(
        didTransition: Bool,
        endedState: LiveVoiceSpeakerEpisodeState? = nil
    ) -> LiveVoiceSpeakerEpisodeObservation {
        .init(
            state: state,
            didTransition: didTransition,
            directContactAtOnset: directContactAtOnset,
            maximumVoiceConfidence: maximumVoiceConfidence,
            endedState: endedState
        )
    }
}
