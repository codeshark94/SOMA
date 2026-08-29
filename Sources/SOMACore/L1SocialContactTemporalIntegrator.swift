import Foundation

public enum L1SocialContactTransition: String, Equatable, Sendable {
    case began
    case ended
}

/// Converts a noisy stream of directed-gaze observations into durable social
/// contact episodes for L1. This is intentionally slower than direct voice
/// admission: a brief gaze can authorize a user-initiated turn without being
/// promoted into a persistent cognitive state transition.
public struct L1SocialContactTemporalIntegrator: Sendable {
    private let beginConfirmationNS: UInt64
    private let endConfirmationNS: UInt64
    private let historyWindowNS: UInt64

    private var stableActive = false
    private var candidateActive: Bool?
    private var candidateSinceNS: UInt64?
    private var activeSinceNS: UInt64?
    private var lastStableObservationNS: UInt64?
    private var episodeStartsNS: [UInt64] = []

    public init(
        beginConfirmationMilliseconds: UInt64 = 1_500,
        endConfirmationMilliseconds: UInt64 = 2_000,
        historyWindowMilliseconds: UInt64 = 45_000
    ) {
        precondition(beginConfirmationMilliseconds > 0)
        precondition(endConfirmationMilliseconds > 0)
        precondition(historyWindowMilliseconds > 0)
        beginConfirmationNS = beginConfirmationMilliseconds * 1_000_000
        endConfirmationNS = endConfirmationMilliseconds * 1_000_000
        historyWindowNS = historyWindowMilliseconds * 1_000_000
    }

    public mutating func observe(
        rawEyeContactActive: Bool,
        at monotonicNS: UInt64
    ) -> L1SocialContactTransition? {
        pruneHistory(at: monotonicNS)

        if rawEyeContactActive == stableActive {
            candidateActive = nil
            candidateSinceNS = nil
            if stableActive { lastStableObservationNS = monotonicNS }
            return nil
        }

        if candidateActive != rawEyeContactActive {
            candidateActive = rawEyeContactActive
            candidateSinceNS = monotonicNS
            return nil
        }

        guard let candidateSinceNS,
              monotonicNS >= candidateSinceNS else {
            self.candidateSinceNS = monotonicNS
            return nil
        }
        let requiredNS = rawEyeContactActive ? beginConfirmationNS : endConfirmationNS
        guard monotonicNS - candidateSinceNS >= requiredNS else { return nil }

        stableActive = rawEyeContactActive
        candidateActive = nil
        self.candidateSinceNS = nil
        if stableActive {
            activeSinceNS = monotonicNS
            lastStableObservationNS = monotonicNS
            episodeStartsNS.append(monotonicNS)
            return .began
        }
        activeSinceNS = nil
        return .ended
    }

    public mutating func snapshot(at monotonicNS: UInt64) -> L1ContactPattern {
        pruneHistory(at: monotonicNS)
        let latestAge = episodeStartsNS.last.map { start in
            monotonicNS >= start ? Double(monotonicNS - start) / 1_000_000_000 : 0
        }
        let activeDuration = stableActive && activeSinceNS != nil && monotonicNS >= activeSinceNS!
            ? Double(monotonicNS - activeSinceNS!) / 1_000_000_000
            : 0
        return L1ContactPattern(
            eyeContactActive: stableActive,
            recentEpisodeCount: episodeStartsNS.count,
            latestEpisodeAgeSeconds: latestAge,
            activeDurationSeconds: activeDuration
        )
    }

    private mutating func pruneHistory(at monotonicNS: UInt64) {
        episodeStartsNS.removeAll { start in
            monotonicNS >= start && monotonicNS - start > historyWindowNS
        }
    }
}
