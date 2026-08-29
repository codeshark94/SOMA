import Foundation

public struct AuditoryOnsetEvidence: Equatable, Sendable {
    public let monotonicNS: UInt64
    public let levelDB: Double
    public let thresholdDB: Double
    public let confidence: Double
    public let transient: Bool

    public init(
        monotonicNS: UInt64,
        levelDB: Double,
        thresholdDB: Double,
        confidence: Double,
        transient: Bool
    ) {
        self.monotonicNS = monotonicNS
        self.levelDB = levelDB
        self.thresholdDB = thresholdDB
        self.confidence = min(max(confidence, 0), 1)
        self.transient = transient
    }
}

/// Converts raw acoustic onsets into motor-worthy evidence. Ordinary room
/// level changes remain perceptual events; they need independent speech
/// confirmation before they can interrupt visual exploration. A genuinely
/// sharp, high-confidence transient remains an immediate orienting stimulus.
public struct AuditoryOrientingAdmission: Sendable {
    private let maximumVoiceConfirmationDelayNS: UInt64
    private let salientTransientConfidence: Double
    private var pendingOnset: AuditoryOnsetEvidence?
    private var voiceEvidence = SustainedVoiceEvidenceAccumulator()
    private var voiceEpisodeActive = false

    public init(
        maximumVoiceConfirmationDelayMilliseconds: UInt64 = 800,
        salientTransientConfidence: Double = 0.80
    ) {
        precondition(maximumVoiceConfirmationDelayMilliseconds > 0)
        precondition(maximumVoiceConfirmationDelayMilliseconds <= UInt64.max / 1_000_000)
        precondition((0...1).contains(salientTransientConfidence))
        maximumVoiceConfirmationDelayNS = maximumVoiceConfirmationDelayMilliseconds * 1_000_000
        self.salientTransientConfidence = salientTransientConfidence
    }

    /// Returns immediate motor evidence only for a sharp, salient transient.
    /// Other onsets remain pending until the neural VAD corroborates them.
    public mutating func observeOnset(_ evidence: AuditoryOnsetEvidence) -> AuditoryOnsetEvidence? {
        pendingOnset = evidence
        guard evidence.transient,
              evidence.confidence >= salientTransientConfidence else {
            return nil
        }
        pendingOnset = nil
        return evidence
    }

    public mutating func observeVoiceActivity(
        active: Bool,
        confidence: Double,
        at monotonicNS: UInt64
    ) -> AuditoryOnsetEvidence? {
        guard active else {
            voiceEpisodeActive = false
            voiceEvidence.reset()
            discardExpiredOnset(at: monotonicNS)
            return nil
        }
        guard !voiceEpisodeActive else { return nil }
        guard voiceEvidence.observe(confidence: confidence, at: monotonicNS) else {
            discardExpiredOnset(at: monotonicNS)
            return nil
        }
        voiceEpisodeActive = true
        guard let pendingOnset,
              monotonicNS >= pendingOnset.monotonicNS,
              monotonicNS - pendingOnset.monotonicNS <= maximumVoiceConfirmationDelayNS else {
            self.pendingOnset = nil
            return nil
        }
        self.pendingOnset = nil
        return pendingOnset
    }

    private mutating func discardExpiredOnset(at monotonicNS: UInt64) {
        guard let pendingOnset,
              monotonicNS >= pendingOnset.monotonicNS,
              monotonicNS - pendingOnset.monotonicNS > maximumVoiceConfirmationDelayNS else {
            return
        }
        self.pendingOnset = nil
    }
}

public struct AuditoryOrientingEpisode: Equatable, Sendable {
    public let requestID: String
    public let startedNS: UInt64
    public let expiresAtNS: UInt64

    public init(requestID: String, startedNS: UInt64, expiresAtNS: UInt64) {
        self.requestID = requestID
        self.startedNS = startedNS
        self.expiresAtNS = expiresAtNS
    }
}

/// Owns one bounded acoustic-orienting episode. Additional acoustic onsets are
/// evidence within the active episode; they cannot replace its identity or
/// extend its deadline and thereby starve visual exploration.
public struct AuditoryOrientingLease: Sendable {
    public let durationNS: UInt64
    public private(set) var activeEpisode: AuditoryOrientingEpisode?

    public init(durationMilliseconds: UInt64 = 4_500) {
        precondition(durationMilliseconds > 0)
        durationNS = durationMilliseconds * 1_000_000
    }

    public var isActive: Bool {
        activeEpisode != nil
    }

    public var activeRequestID: String? {
        activeEpisode?.requestID
    }

    /// Acquires the lease only when no orienting episode is active. The fixed
    /// deadline is created once and is never refreshed by later onsets.
    public mutating func begin(requestID: String, at monotonicNS: UInt64) -> AuditoryOrientingEpisode? {
        guard activeEpisode == nil, !requestID.isEmpty else { return nil }
        let deadline = monotonicNS.addingReportingOverflow(durationNS)
        let episode = AuditoryOrientingEpisode(
            requestID: requestID,
            startedNS: monotonicNS,
            expiresAtNS: deadline.overflow ? UInt64.max : deadline.partialValue
        )
        activeEpisode = episode
        return episode
    }

    public func contains(requestID: String) -> Bool {
        activeEpisode?.requestID == requestID
    }

    @discardableResult
    public mutating func end() -> AuditoryOrientingEpisode? {
        defer { activeEpisode = nil }
        return activeEpisode
    }
}
