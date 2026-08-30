import Foundation

public enum NativeTrackingRecoveryState: String, Equatable, Sendable {
    case tracking
    case reacquiring
    case targetLost
}

/// Distinguishes a brief detector dropout from a native tracker that has
/// actually lost its person. Fresh human evidence immediately restores the
/// tracking state. During absence, measured gimbal motion grants the firmware
/// a bounded opportunity to finish following the target; a stationary gimbal
/// confirms loss sooner because it has no active recovery trajectory.
public struct NativeTrackingRecovery: Sendable {
    private let initialAbsenceConfirmationNS: UInt64
    private let stationaryConfirmationNS: UInt64
    private let maximumRecoveryNS: UInt64
    private let stationaryAngularSpeed: Double

    private var lastHumanObservationNS: UInt64?
    private var lossStartedNS: UInt64?
    private var stationarySinceNS: UInt64?

    public private(set) var state: NativeTrackingRecoveryState = .tracking

    public init(
        initialAbsenceConfirmationMilliseconds: UInt64 = 250,
        stationaryConfirmationMilliseconds: UInt64 = 350,
        maximumRecoveryMilliseconds: UInt64 = 2_000,
        stationaryAngularSpeedDegreesPerSecond: Double = 0.8
    ) {
        initialAbsenceConfirmationNS = initialAbsenceConfirmationMilliseconds * 1_000_000
        stationaryConfirmationNS = stationaryConfirmationMilliseconds * 1_000_000
        maximumRecoveryNS = maximumRecoveryMilliseconds * 1_000_000
        stationaryAngularSpeed = max(0, stationaryAngularSpeedDegreesPerSecond)
    }

    public mutating func recordHumanObservation(at monotonicNS: UInt64) {
        lastHumanObservationNS = monotonicNS
        lossStartedNS = nil
        stationarySinceNS = nil
        state = .tracking
    }

    public mutating func evaluateAbsence(
        at monotonicNS: UInt64,
        measuredVelocity: GimbalVelocityFeedback?
    ) -> NativeTrackingRecoveryState {
        if state == .targetLost { return .targetLost }
        if let lastHumanObservationNS,
           monotonicNS < lastHumanObservationNS + initialAbsenceConfirmationNS {
            state = .tracking
            return state
        }

        let started = lossStartedNS ?? lastHumanObservationNS ?? monotonicNS
        lossStartedNS = started
        state = .reacquiring

        if monotonicNS >= started + maximumRecoveryNS {
            state = .targetLost
            return state
        }

        if let measuredVelocity {
            let angularSpeed = hypot(
                measuredVelocity.pitchDegreesPerSecond,
                measuredVelocity.panDegreesPerSecond
            )
            if angularSpeed <= stationaryAngularSpeed {
                let stationarySince = stationarySinceNS ?? monotonicNS
                stationarySinceNS = stationarySince
                if monotonicNS >= stationarySince + stationaryConfirmationNS {
                    state = .targetLost
                }
            } else {
                stationarySinceNS = nil
            }
        } else {
            // Missing attitude feedback is not evidence that the device is
            // stationary. The bounded maximum-recovery deadline remains the
            // authoritative fallback.
            stationarySinceNS = nil
        }
        return state
    }

    public mutating func reset() {
        lastHumanObservationNS = nil
        lossStartedNS = nil
        stationarySinceNS = nil
        state = .tracking
    }
}
