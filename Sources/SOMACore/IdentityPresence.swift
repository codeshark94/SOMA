import Foundation

/// A local, opaque identity that has passed the face-recognition runtime's
/// own confirmation threshold. It deliberately carries no biometric material
/// and no display name.
public struct IdentityPresenceIdentity: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case enrolled
        case pseudonymous
    }

    public let entityID: UUID
    public let kind: Kind

    public init(entityID: UUID, kind: Kind) {
        self.entityID = entityID
        self.kind = kind
    }
}

/// Discrete social-presence transitions. Continuous recognition samples do
/// not produce events: consumers react to arrivals, confirmed replacements,
/// and departures rather than frame-rate identity chatter.
public enum IdentityPresenceTransition: Equatable, Sendable {
    case arrived(IdentityPresenceIdentity)
    case replacementCandidate(
        previous: IdentityPresenceIdentity,
        candidate: IdentityPresenceIdentity,
        confirmations: Int
    )
    case replaced(previous: IdentityPresenceIdentity, current: IdentityPresenceIdentity)
    case departed(IdentityPresenceIdentity)
}

/// Maintains the identity of one locally observed social participant across
/// detector and open-set recognition gaps. A different recognized identity
/// must recur before it replaces the current participant; visual absence is
/// separately required before a participant departs.
public struct IdentityPresenceTracker: Sendable {
    public struct Timing: Equatable, Sendable {
        public let departureAfterMilliseconds: UInt64
        public let replacementEvidenceWindowMilliseconds: UInt64
        public let replacementConfirmationsRequired: Int

        public init(
            departureAfterMilliseconds: UInt64 = 2_500,
            replacementEvidenceWindowMilliseconds: UInt64 = 900,
            replacementConfirmationsRequired: Int = 2
        ) {
            precondition(departureAfterMilliseconds > 0)
            precondition(replacementEvidenceWindowMilliseconds > 0)
            precondition(replacementConfirmationsRequired >= 2)
            self.departureAfterMilliseconds = departureAfterMilliseconds
            self.replacementEvidenceWindowMilliseconds = replacementEvidenceWindowMilliseconds
            self.replacementConfirmationsRequired = replacementConfirmationsRequired
        }
    }

    private struct PendingReplacement: Sendable {
        let identity: IdentityPresenceIdentity
        let firstObservedNS: UInt64
        let confirmations: Int
    }

    private let timing: Timing
    private var active: IdentityPresenceIdentity?
    private var lastVerifiedFaceNS: UInt64?
    private var pendingReplacement: PendingReplacement?

    public init(timing: Timing = .init()) {
        self.timing = timing
    }

    public var currentIdentity: IdentityPresenceIdentity? { active }

    /// Records independently verified face evidence. The evidence confirms
    /// that somebody remains present but does not by itself assert that the
    /// active identity is still the same person.
    public mutating func recordVerifiedFace(at monotonicNS: UInt64) {
        guard lastVerifiedFaceNS.map({ monotonicNS >= $0 }) ?? true else { return }
        lastVerifiedFaceNS = monotonicNS
    }

    /// Advances absence time. Call it from the visual pipeline even when no
    /// face-recognition inference is emitted, so departure is about genuine
    /// visual absence rather than a stalled identity worker.
    public mutating func advance(at monotonicNS: UInt64) -> [IdentityPresenceTransition] {
        guard let active,
              let lastVerifiedFaceNS,
              monotonicNS >= lastVerifiedFaceNS,
              monotonicNS - lastVerifiedFaceNS >= nanoseconds(timing.departureAfterMilliseconds) else {
            return []
        }
        self.active = nil
        self.lastVerifiedFaceNS = nil
        pendingReplacement = nil
        return [.departed(active)]
    }

    /// Adds a locally recognized identity. A short-lived mismatch becomes a
    /// replacement candidate, not an immediate social handoff. If an existing
    /// participant has already departed, the incoming identity is a new
    /// arrival rather than a replacement.
    public mutating func observe(
        _ identity: IdentityPresenceIdentity,
        at monotonicNS: UInt64
    ) -> [IdentityPresenceTransition] {
        var transitions = advance(at: monotonicNS)
        recordVerifiedFace(at: monotonicNS)
        guard let active else {
            self.active = identity
            pendingReplacement = nil
            transitions.append(.arrived(identity))
            return transitions
        }
        guard active != identity else {
            pendingReplacement = nil
            return transitions
        }

        let windowNS = nanoseconds(timing.replacementEvidenceWindowMilliseconds)
        let pending: PendingReplacement
        if let current = pendingReplacement,
           current.identity == identity,
           monotonicNS >= current.firstObservedNS,
           monotonicNS - current.firstObservedNS <= windowNS {
            pending = PendingReplacement(
                identity: identity,
                firstObservedNS: current.firstObservedNS,
                confirmations: current.confirmations + 1
            )
        } else {
            pending = PendingReplacement(
                identity: identity,
                firstObservedNS: monotonicNS,
                confirmations: 1
            )
        }

        if pending.confirmations >= timing.replacementConfirmationsRequired {
            self.active = identity
            pendingReplacement = nil
            transitions.append(.replaced(previous: active, current: identity))
        } else {
            pendingReplacement = pending
            transitions.append(.replacementCandidate(
                previous: active,
                candidate: identity,
                confirmations: pending.confirmations
            ))
        }
        return transitions
    }

    private func nanoseconds(_ milliseconds: UInt64) -> UInt64 {
        milliseconds * 1_000_000
    }
}
