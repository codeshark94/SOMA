import Foundation

/// Keeps an eligible, recently observed human as L0's social target across
/// detector cadence gaps. It suppresses only default object attention; an
/// explicit future L1 attention weight is allowed to take control.
public struct SocialAttentionLease: Sendable {
    private let durationNS: UInt64
    private var expiresNS: UInt64 = 0

    public init(durationMilliseconds: UInt64 = 2_500) {
        durationNS = durationMilliseconds * 1_000_000
    }

    public mutating func recordEligibleHuman(at monotonicNS: UInt64) {
        expiresNS = monotonicNS + durationNS
    }

    public func suppressesDefaultNonHumanAttention(
        candidates: [VisualObservation],
        at monotonicNS: UInt64
    ) -> Bool {
        guard monotonicNS < expiresNS,
              !candidates.contains(where: { $0.kind == .human && $0.isActionEligible }) else {
            return false
        }
        return !candidates.contains(where: { $0.kind != .human && $0.attentionWeight > 0 })
    }
}
