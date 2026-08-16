import Foundation

/// The L0 controller's behavioural state. This selects where attention should
/// be directed; it deliberately does not encode a motor command.
public enum SubconsciousAttentionState: String, Codable, Equatable, Sendable {
    case idle
    case socialFixation = "social_fixation"
    case socialReframing = "social_reframing"
    case socialRetention = "social_retention"
    case sceneObservation = "scene_observation"
    case exploration
}

/// The provenance of an update presented to the controller. Only a completed
/// visual observation can start a physical social-tracking lease.
public enum SubconsciousAttentionEvidence: Sendable {
    case visualObservation
    case visualLoss
    case nonVisualUpdate
}

/// A hardware-independent L0 control decision. Native tracking is an optional
/// actuator adapter for social fixation, not the definition of attention.
public struct SubconsciousAttentionDecision: Equatable, Sendable {
    public let state: SubconsciousAttentionState
    public let sceneID: String?
    public let posteriorProbability: Double
    public let permitsNativeSocialTracking: Bool
    public let permitsExternalSocialReframing: Bool
    public let suppressesExploration: Bool

    /// Non-motor scene or provisional social evidence may prevent a new blind
    /// search from starting, but it has no L0 motor authority to cut an
    /// already active coverage trajectory.
    public var preservesActiveExploration: Bool {
        (state == .sceneObservation || state == .socialRetention)
            && !permitsNativeSocialTracking
            && !permitsExternalSocialReframing
    }

    public init(
        state: SubconsciousAttentionState,
        sceneID: String?,
        posteriorProbability: Double,
        permitsNativeSocialTracking: Bool,
        permitsExternalSocialReframing: Bool,
        suppressesExploration: Bool
    ) {
        self.state = state
        self.sceneID = sceneID
        self.posteriorProbability = min(max(posteriorProbability, 0), 1)
        self.permitsNativeSocialTracking = permitsNativeSocialTracking
        self.permitsExternalSocialReframing = permitsExternalSocialReframing
        self.suppressesExploration = suppressesExploration
    }
}

/// Separates probabilistic attention selection from physical control.
///
/// Faces are high-value social evidence. Objects and unlabelled regions remain
/// first-class scene hypotheses, but at L0 they lead to observation rather
/// than an uncalibrated gimbal fixation. A future L1 may add a separate,
/// explicit object-actuation policy without changing this controller.
public struct SubconsciousAttentionController: Sendable {
    public private(set) var state: SubconsciousAttentionState = .idle
    private var observedSceneID: String?
    private var sceneObservationStartedNS: UInt64?

    public init() {}

    public mutating func advance(
        belief: BeliefSnapshot,
        evidence: SubconsciousAttentionEvidence,
        socialFixationPermitted: Bool,
        nativeSocialTrackingPermitted: Bool? = nil,
        nativeSocialTrackingActive: Bool = false
    ) -> SubconsciousAttentionDecision {
        let nativeSocialTrackingPermitted = nativeSocialTrackingPermitted
            ?? socialFixationPermitted
        switch evidence {
        case .nonVisualUpdate:
            return decision(
                state: state,
                target: belief.target,
                permitsNativeSocialTracking: false,
                permitsExternalSocialReframing: false,
                suppressesExploration: state == .socialFixation || state == .socialReframing || state == .socialRetention || state == .sceneObservation
            )

        case .visualLoss:
            clearSceneObservation()
            state = socialFixationPermitted ? .socialRetention : .exploration
            let nativeLeaseRetained = socialFixationPermitted && nativeSocialTrackingActive
            return decision(
                state: state,
                target: nil,
                permitsNativeSocialTracking: false,
                permitsExternalSocialReframing: false,
                // Native tracking already owns its own live visual loop. An
                // app-detector gap must not tear that loop down; if native
                // ownership is absent, the bridge remains free to reacquire
                // the remembered face spatially.
                suppressesExploration: nativeLeaseRetained
            )

        case .visualObservation:
            guard let target = belief.target, belief.targetStatus == .tracked else {
                state = socialFixationPermitted ? .socialRetention : .exploration
                return decision(
                    state: state,
                    target: nil,
                    permitsNativeSocialTracking: false,
                    permitsExternalSocialReframing: false,
                    suppressesExploration: state == .socialRetention
                )
            }

            if socialFixationPermitted {
                clearSceneObservation()
                if nativeSocialTrackingActive,
                   target.kind == .human,
                   target.label != "face" {
                    // The person detector is a lower-resolution observation of
                    // the same social target, not permission to tear down an
                    // already confirmed native face fixation. If native
                    // tracking is not active, the body may still drive the
                    // bounded face-reframing path below.
                    state = .socialRetention
                    return decision(
                        state: state,
                        target: target,
                        permitsNativeSocialTracking: false,
                        permitsExternalSocialReframing: false,
                        suppressesExploration: true
                    )
                }
                let canReframe = target.kind == .human
                    && target.label != "face"
                    && target.isActionEligible
                    && target.confidence >= 0.60
                    && target.posteriorProbability >= 0.18
                state = target.isFaceMotorTarget
                    ? .socialFixation
                    : (canReframe ? .socialReframing : .exploration)
                return decision(
                    state: state,
                    target: target,
                    permitsNativeSocialTracking: state == .socialFixation
                        && nativeSocialTrackingPermitted,
                    permitsExternalSocialReframing: canReframe,
                    suppressesExploration: true
                )
            }

            if target.kind == .human {
                clearSceneObservation()
                let canReframe = target.isActionEligible
                    && target.label != "face"
                    && target.confidence >= 0.60
                    && target.posteriorProbability >= 0.18
                state = canReframe ? .socialReframing : .exploration
                return decision(
                    state: state,
                    target: target,
                    permitsNativeSocialTracking: false,
                    permitsExternalSocialReframing: canReframe,
                    suppressesExploration: true
                )
            }

            let startedNS: UInt64
            if observedSceneID == target.id, let sceneObservationStartedNS {
                startedNS = sceneObservationStartedNS
            } else {
                observedSceneID = target.id
                sceneObservationStartedNS = belief.monotonicNS
                startedNS = belief.monotonicNS
            }
            if belief.monotonicNS >= startedNS + sceneObservationDwellNS(for: target) {
                state = .exploration
                return decision(
                    state: state,
                    target: target,
                    permitsNativeSocialTracking: false,
                    permitsExternalSocialReframing: false,
                    suppressesExploration: false
                )
            }
            state = .sceneObservation
            return decision(
                state: state,
                target: target,
                permitsNativeSocialTracking: false,
                permitsExternalSocialReframing: false,
                suppressesExploration: true
            )
        }
    }

    /// A non-human candidate gets a probability-weighted look, then yields to
    /// active coverage. The scene record remains available for later L1
    /// reasoning and re-observation; this only prevents a static texture from
    /// pinning the optical axis indefinitely.
    private func sceneObservationDwellNS(for target: AttentionTarget) -> UInt64 {
        let seconds = 0.25 + target.posteriorProbability * 0.45
        return UInt64(seconds * 1_000_000_000)
    }

    private mutating func clearSceneObservation() {
        observedSceneID = nil
        sceneObservationStartedNS = nil
    }

    private func decision(
        state: SubconsciousAttentionState,
        target: AttentionTarget?,
        permitsNativeSocialTracking: Bool,
        permitsExternalSocialReframing: Bool,
        suppressesExploration: Bool
    ) -> SubconsciousAttentionDecision {
        SubconsciousAttentionDecision(
            state: state,
            sceneID: target?.id,
            posteriorProbability: target?.posteriorProbability ?? 0,
            permitsNativeSocialTracking: permitsNativeSocialTracking,
            permitsExternalSocialReframing: permitsExternalSocialReframing,
            suppressesExploration: suppressesExploration
        )
    }
}
