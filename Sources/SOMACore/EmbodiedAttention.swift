import Foundation

public enum CameraControlOwner: String, Codable, Equatable, Sendable {
    case manual
    case nativeAI = "native_ai"
    case external
    case fault
}

public enum NonverbalAttentionState: String, Codable, Equatable, Sendable {
    case blocked
    case yield
    case orient
    case hold
    case soften
}

public enum AttentionActuatorRoute: String, Codable, Equatable, Sendable {
    case none
    case nativeHumanTracking = "native_human_tracking"
    case externalVisualControl = "external_visual_control"
}

public struct EmbodiedAttentionDirective: Codable, Equatable, Sendable {
    public let owner: CameraControlOwner
    public let state: NonverbalAttentionState
    public let horizontalError: Double
    public let verticalError: Double
    public let externalPanSpeed: Double
    public let externalTiltSpeed: Double
    public let nativeHumanTrackingRequested: Bool
    public let stopRequested: Bool
    public let route: AttentionActuatorRoute
}

/// Turns local attention evidence into a bounded camera-control recommendation.
/// It never emits a device command: only the current owner may consume it.
public struct EmbodiedAttentionPolicy: Sendable {
    private let horizontalDeadZone = 0.09
    private let verticalDeadZone = 0.11

    public init() {}

    public func directive(
        for belief: BeliefSnapshot,
        owner: CameraControlOwner
    ) -> EmbodiedAttentionDirective {
        guard let target = belief.target, belief.targetStatus == .tracked else {
            return EmbodiedAttentionDirective(
                owner: owner,
                state: owner == .nativeAI ? .soften : .yield,
                horizontalError: 0,
                verticalError: 0,
                externalPanSpeed: 0,
                externalTiltSpeed: 0,
                nativeHumanTrackingRequested: false,
                stopRequested: owner == .external || owner == .nativeAI,
                route: .none
            )
        }

        let horizontalError = target.rect.centerX - 0.5
        let verticalError = target.rect.centerY - 0.5
        let inDeadZone = abs(horizontalError) <= horizontalDeadZone
            && abs(verticalError) <= verticalDeadZone
        let state: NonverbalAttentionState
        if inDeadZone {
            state = .hold
        } else if target.confidence < 0.45 || belief.uncertainty > 0.65 {
            state = .soften
        } else {
            state = .orient
        }
        let route: AttentionActuatorRoute = target.permitsL0MotorControl
            ? .externalVisualControl
            : .none

        switch owner {
        case .nativeAI:
            return EmbodiedAttentionDirective(
                owner: owner,
                state: state,
                horizontalError: horizontalError,
                verticalError: verticalError,
                externalPanSpeed: 0,
                externalTiltSpeed: 0,
                nativeHumanTrackingRequested: target.isFaceMotorTarget,
                stopRequested: !target.isFaceMotorTarget,
                route: target.isFaceMotorTarget ? .nativeHumanTracking : .none
            )
        case .external:
            return EmbodiedAttentionDirective(
                owner: owner,
                state: state,
                horizontalError: horizontalError,
                verticalError: verticalError,
                externalPanSpeed: 0,
                externalTiltSpeed: 0,
                nativeHumanTrackingRequested: false,
                stopRequested: route == .none,
                route: route
            )
        case .manual, .fault:
            return EmbodiedAttentionDirective(
                owner: owner,
                state: .blocked,
                horizontalError: horizontalError,
                verticalError: verticalError,
                externalPanSpeed: 0,
                externalTiltSpeed: 0,
                nativeHumanTrackingRequested: false,
                stopRequested: false,
                route: route
            )
        }
    }

}

/// Enforces a single actuator owner. A failed acknowledgement is never silently
/// converted into another owner; the caller must explicitly recover to manual.
public struct CameraOwnerArbiter: Equatable, Sendable {
    public private(set) var owner: CameraControlOwner

    public init(owner: CameraControlOwner = .manual) {
        self.owner = owner
    }

    @discardableResult
    public mutating func request(_ requestedOwner: CameraControlOwner) -> Bool {
        guard owner == .manual, requestedOwner == .nativeAI || requestedOwner == .external else {
            return false
        }
        owner = requestedOwner
        return true
    }

    public mutating func recordFault() {
        owner = .fault
    }

    @discardableResult
    public mutating func confirmManualStop() -> Bool {
        guard owner == .nativeAI || owner == .external || owner == .fault else { return false }
        owner = .manual
        return true
    }
}

public enum NativeHumanTrackingAction: Equatable, Sendable {
    case none
    case start
    case heartbeat
    case stop
}

/// Converts a credible human posterior into a bounded native-tracking lease.
/// A loss, an object target, or an expired lease never leaves the human tracker
/// active. The caller supplies transport-specific command IDs separately.
public struct NativeHumanTrackingGate: Sendable {
    private static let acquisitionNS: UInt64 = 160_000_000
    private var eligibleSinceNS: UInt64?
    private var active = false
    private var lastHeartbeatNS: UInt64 = 0

    public init() {}

    /// The bridge must retain this ownership between 200 ms heartbeats; action
    /// values are sparse transport updates, not a per-frame ownership signal.
    public var isActive: Bool { active }

    public mutating func update(
        _ belief: BeliefSnapshot,
        hasVisualEvidence: Bool = true,
        immediateAcquisitionPermitted: Bool = false
    ) -> NativeHumanTrackingAction {
        guard hasVisualEvidence else { return invalidate() }
        guard let target = belief.target,
              target.isFaceMotorTarget else {
            eligibleSinceNS = nil
            if active {
                active = false
                return .stop
            }
            return .none
        }

        // Acquisition needs strong evidence. Once a verified face has handed
        // off to the device's native tracker, a one-frame probability dip is
        // not evidence that the person disappeared and must not release motor
        // ownership.
        if active {
            guard belief.monotonicNS >= lastHeartbeatNS + 200_000_000 else { return .none }
            lastHeartbeatNS = belief.monotonicNS
            return .heartbeat
        }

        guard target.confidence >= 0.60,
              target.posteriorProbability >= 0.18 else {
            eligibleSinceNS = nil
            return .none
        }

        // The normal 160 ms lease protects first acquisition from a one-frame
        // false positive. Once an independently verified face lock already
        // exists, requiring that lease again makes a brief face reappearance
        // during camera motion impossible to catch.
        if immediateAcquisitionPermitted {
            eligibleSinceNS = nil
            active = true
            lastHeartbeatNS = belief.monotonicNS
            return .start
        }
        let since = eligibleSinceNS ?? belief.monotonicNS
        eligibleSinceNS = since
        guard belief.monotonicNS >= since + Self.acquisitionNS else { return .none }
        active = true
        lastHeartbeatNS = belief.monotonicNS
        return .start
    }

    /// Begins a device-native acquisition from two temporally matched ANE face
    /// observations.  This is deliberately separate from `update`: the world
    /// model's decayed posterior represents sustained attention, whereas the
    /// native tracker needs the current image-space box before a fast-moving
    /// face leaves the frame.  Callers must first establish the bounded
    /// provisional FaceLockLease; this method never confers identity,
    /// conversation, or persistent social authority by itself.
    public mutating func acquireFromTemporalFaceEvidence(
        at monotonicNS: UInt64
    ) -> NativeHumanTrackingAction {
        guard !active else {
            return heartbeatIfActive(at: monotonicNS)
        }
        eligibleSinceNS = nil
        active = true
        lastHeartbeatNS = monotonicNS
        return .start
    }

    public mutating func stop() -> NativeHumanTrackingAction {
        eligibleSinceNS = nil
        guard active else { return .none }
        active = false
        return .stop
    }

    /// SceneField can observe the held face even when the probabilistic
    /// selector publishes a simultaneous body or saliency candidate. Refresh
    /// the native helper from that direct face evidence so selection cadence
    /// cannot accidentally trip its ownership watchdog.
    public mutating func heartbeatIfActive(at monotonicNS: UInt64) -> NativeHumanTrackingAction {
        guard active,
              monotonicNS >= lastHeartbeatNS + 200_000_000 else {
            return .none
        }
        lastHeartbeatNS = monotonicNS
        return .heartbeat
    }

    public mutating func invalidate() -> NativeHumanTrackingAction {
        stop()
    }
}
