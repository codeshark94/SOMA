import Foundation

public enum NativeTrackingLivenessState: Equatable, Sendable {
    case superseded
    case observing
    case confirmed
    case unresponsive
}

/// Verifies that an accepted native-tracking request produces observable
/// target-centering behavior before the higher-level controller treats it as
/// a reliable motor owner.
public struct NativeTrackingLiveness: Sendable {
    private struct Attempt: Sendable {
        let token: UInt64
        var startedNS: UInt64
        var deadlineNS: UInt64
        var startingOffset: Double?
        var startingPose: GimbalPose?
    }

    private let acquisitionTimeoutNS: UInt64
    private let centeredConfirmationNS: UInt64
    private let centeredOffset: Double
    private let requiredOffsetImprovement: Double
    private let minimumPoseMotionDegrees: Double
    private var nextToken: UInt64 = 0
    private var attempt: Attempt?

    public init(
        acquisitionTimeoutMilliseconds: UInt64 = 2_500,
        centeredConfirmationMilliseconds: UInt64 = 400,
        centeredOffset: Double = 0.12,
        requiredOffsetImprovement: Double = 0.06,
        minimumPoseMotionDegrees: Double = 0.50
    ) {
        acquisitionTimeoutNS = acquisitionTimeoutMilliseconds * 1_000_000
        centeredConfirmationNS = min(
            centeredConfirmationMilliseconds,
            acquisitionTimeoutMilliseconds
        ) * 1_000_000
        self.centeredOffset = centeredOffset
        self.requiredOffsetImprovement = requiredOffsetImprovement
        self.minimumPoseMotionDegrees = minimumPoseMotionDegrees
    }

    public var acquisitionTimeoutMilliseconds: Int {
        Int(acquisitionTimeoutNS / 1_000_000)
    }

    @discardableResult
    public mutating func begin(
        target: NormalizedRect?,
        pose: GimbalPose?,
        at monotonicNS: UInt64
    ) -> UInt64 {
        nextToken &+= 1
        attempt = Attempt(
            token: nextToken,
            startedNS: monotonicNS,
            deadlineNS: monotonicNS + acquisitionTimeoutNS,
            startingOffset: target.map(Self.targetOffset),
            startingPose: pose
        )
        return nextToken
    }

    public mutating func cancel() {
        attempt = nil
    }

    public mutating func evaluate(
        token: UInt64,
        target: NormalizedRect?,
        pose: GimbalPose?,
        at monotonicNS: UInt64
    ) -> NativeTrackingLivenessState {
        guard var attempt, attempt.token == token else { return .superseded }
        let currentOffset = target.map(Self.targetOffset)
        if let startingOffset = attempt.startingOffset,
           let currentOffset,
           currentOffset <= startingOffset - requiredOffsetImprovement,
           moved(from: attempt.startingPose, to: pose) {
            self.attempt = nil
            return .confirmed
        }

        // A centered target produces no motor displacement to observe. Once
        // the device has accepted the native mode, an independently observed
        // face that remains centered through a short dwell is sufficient
        // evidence that the native loop is holding its target. If the face
        // moves away first, replace the dwell with the normal measurable
        // re-centering challenge.
        if let startingOffset = attempt.startingOffset,
           startingOffset <= centeredOffset {
            guard let currentOffset else {
                guard monotonicNS >= attempt.deadlineNS else {
                    self.attempt = attempt
                    return .observing
                }
                self.attempt = nil
                return .unresponsive
            }
            if currentOffset > centeredOffset {
                attempt.startedNS = monotonicNS
                attempt.deadlineNS = monotonicNS + acquisitionTimeoutNS
                attempt.startingOffset = currentOffset
                attempt.startingPose = pose
                self.attempt = attempt
                return .observing
            }
            if currentOffset <= centeredOffset,
               monotonicNS >= attempt.startedNS + centeredConfirmationNS {
                self.attempt = nil
                return .confirmed
            }
            if currentOffset <= centeredOffset,
               moved(from: attempt.startingPose, to: pose) {
                self.attempt = nil
                return .confirmed
            }
            // Keep waiting until the centered dwell completes or a measurable
            // displacement presents a re-centering challenge.
            self.attempt = attempt
            return .observing
        }
        guard monotonicNS >= attempt.deadlineNS else { return .observing }
        self.attempt = nil
        return .unresponsive
    }

    private func moved(from start: GimbalPose?, to current: GimbalPose?) -> Bool {
        guard let start, let current,
              current.monotonicNS >= start.monotonicNS else {
            return false
        }
        return hypot(
            current.pitchDegrees - start.pitchDegrees,
            current.panDegrees - start.panDegrees
        ) >= minimumPoseMotionDegrees
    }

    private static func targetOffset(_ target: NormalizedRect) -> Double {
        hypot(target.centerX - 0.5, target.centerY - 0.5)
    }
}
