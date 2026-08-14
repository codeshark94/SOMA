import Foundation

/// A single empty detector result is ambiguous: it can be blur, a mailbox
/// replacement, or a detector cadence gap. Only a continuous empty interval
/// constitutes visual loss for an actuator.
public struct VisualEvidenceContinuity: Sendable {
    private let lossConfirmationNS: UInt64
    private var lastObservationNS: UInt64?

    public init(lossConfirmationMilliseconds: UInt64 = 250) {
        lossConfirmationNS = lossConfirmationMilliseconds * 1_000_000
    }

    public mutating func recordObservation(at monotonicNS: UInt64) {
        lastObservationNS = monotonicNS
    }

    /// Returns true only after the last completed visual observation has been
    /// absent for the configured interval. Before any observation, absence is
    /// already confirmed, which is appropriate for idle exploration.
    public mutating func confirmsLoss(at monotonicNS: UInt64) -> Bool {
        guard let lastObservationNS else { return true }
        guard monotonicNS >= lastObservationNS + lossConfirmationNS else { return false }
        self.lastObservationNS = nil
        return true
    }
}
