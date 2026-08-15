import Foundation

/// A motor intent accepted by the cognitive lease arbiter. These values stay
/// semantic: the L0 runtime still owns pose feedback, route planning, command
/// rates, watchdogs, and the SDK transport.
public enum EmbodimentMotorIntent: Equatable, Sendable {
    case orient(
        requestID: String,
        bearing: GimbalRelativeBearing,
        toleranceDegrees: Double,
        motionStyle: EmbodimentMotionStyle,
        expiresAtNS: UInt64,
        reason: String
    )
    case track(
        requestID: String,
        targetReference: String,
        sceneID: String,
        bearing: GimbalRelativeBearing,
        observedThisFrame: Bool,
        motionStyle: EmbodimentMotionStyle,
        expiresAtNS: UInt64
    )
    case capture(
        requestID: String,
        targetReference: String?,
        sceneID: String?,
        bearing: GimbalRelativeBearing,
        fieldOfViewDegrees: Double,
        expiresAtNS: UInt64
    )
    case explore(
        requestID: String,
        policy: ExplorationPolicyGoal,
        expiresAtNS: UInt64
    )
    case express(
        requestID: String,
        expression: SocialGimbalExpression,
        expiresAtNS: UInt64
    )
    /// The lease remains authoritative, but L0 must not move until the goal
    /// becomes grounded again.
    case suspend(requestID: String, reason: String, expiresAtNS: UInt64)
    /// Relinquishes cognitive motor authority and returns the actuator to L0.
    case release(requestID: String?, reason: String)
}

/// Converts accepted cognitive requests into semantic L0 motor intents. It
/// deliberately has no SDK or timer dependency so ownership, grounding, and
/// expiry rules can be verified independently of hardware.
public struct EmbodimentMotorCoordinator: Sendable {
    private var activeRequest: CognitiveEmbodimentRequest?
    private var lastFingerprint: String?

    public init() {}

    public var activeRequestID: String? { activeRequest?.requestID }
    public var activeExpiresAtNS: UInt64? { activeRequest?.lease.expiresAtNS }

    public mutating func apply(
        request: CognitiveEmbodimentRequest,
        decision: EmbodimentShadowDecision,
        at monotonicNS: UInt64
    ) -> EmbodimentMotorIntent? {
        guard decision.status != .rejected else { return nil }

        if case .release = request.operation {
            guard activeRequest?.lease.ownerID == request.lease.ownerID else { return nil }
            let releasedID = activeRequest?.requestID
            activeRequest = nil
            lastFingerprint = nil
            return .release(requestID: releasedID, reason: "owner_released")
        }

        guard request.operation.claimsMotorLease else {
            guard let activeRequest,
                  decision.snapshot.activeRequestID != activeRequest.requestID else { return nil }
            self.activeRequest = nil
            lastFingerprint = nil
            return .release(requestID: activeRequest.requestID, reason: "goal_invalidated")
        }

        guard decision.status == .accepted,
              decision.snapshot.activeRequestID == request.requestID else { return nil }
        activeRequest = request
        lastFingerprint = nil
        return resolve(snapshot: decision.snapshot, at: monotonicNS)
    }

    public mutating func update(
        snapshot: EmbodimentShadowSnapshot,
        at monotonicNS: UInt64
    ) -> EmbodimentMotorIntent? {
        guard let activeRequest else { return nil }
        guard snapshot.activeRequestID == activeRequest.requestID else {
            self.activeRequest = nil
            lastFingerprint = nil
            return .release(requestID: activeRequest.requestID, reason: "goal_invalidated")
        }
        return resolve(snapshot: snapshot, at: monotonicNS)
    }

    public mutating func expire(at monotonicNS: UInt64) -> EmbodimentMotorIntent? {
        guard let activeRequest,
              activeRequest.lease.expiresAtNS <= monotonicNS else { return nil }
        self.activeRequest = nil
        lastFingerprint = nil
        return .release(requestID: activeRequest.requestID, reason: "lease_expired")
    }

    public mutating func stop(reason: String = "runtime_stopped") -> EmbodimentMotorIntent? {
        guard let activeRequest else { return nil }
        self.activeRequest = nil
        lastFingerprint = nil
        return .release(requestID: activeRequest.requestID, reason: reason)
    }

    public mutating func complete(
        requestID: String,
        reason: String = "capture_completed"
    ) -> EmbodimentMotorIntent? {
        guard activeRequest?.requestID == requestID else { return nil }
        activeRequest = nil
        lastFingerprint = nil
        return .release(requestID: requestID, reason: reason)
    }

    private mutating func resolve(
        snapshot: EmbodimentShadowSnapshot,
        at monotonicNS: UInt64
    ) -> EmbodimentMotorIntent? {
        guard let request = activeRequest else { return nil }
        guard request.lease.expiresAtNS > monotonicNS else {
            activeRequest = nil
            lastFingerprint = nil
            return .release(requestID: request.requestID, reason: "lease_expired")
        }

        let intent: EmbodimentMotorIntent
        switch request.operation {
        case let .orient(goal):
            intent = .orient(
                requestID: request.requestID,
                bearing: goal.bearing,
                toleranceDegrees: goal.toleranceDegrees,
                motionStyle: goal.motionStyle,
                expiresAtNS: request.lease.expiresAtNS,
                reason: "explicit_orientation"
            )
        case let .trackTarget(goal):
            intent = groundedTargetIntent(
                requestID: request.requestID,
                targetReference: goal.targetReference,
                motionStyle: goal.motionStyle,
                reacquireIfOccluded: goal.reacquireIfOccluded,
                expiresAtNS: request.lease.expiresAtNS,
                snapshot: snapshot
            )
        case let .captureView(goal):
            if let bearing = goal.bearing {
                intent = .capture(
                    requestID: request.requestID,
                    targetReference: nil,
                    sceneID: nil,
                    bearing: bearing,
                    fieldOfViewDegrees: goal.fieldOfViewDegrees ?? 70,
                    expiresAtNS: request.lease.expiresAtNS
                )
            } else if let targetReference = goal.targetReference {
                intent = groundedCaptureIntent(
                    requestID: request.requestID,
                    targetReference: targetReference,
                    fieldOfViewDegrees: goal.fieldOfViewDegrees ?? 70,
                    expiresAtNS: request.lease.expiresAtNS,
                    snapshot: snapshot
                )
            } else {
                intent = .suspend(
                    requestID: request.requestID,
                    reason: "capture_goal_unresolved",
                    expiresAtNS: request.lease.expiresAtNS
                )
            }
        case let .explore(policy):
            intent = .explore(
                requestID: request.requestID,
                policy: policy,
                expiresAtNS: request.lease.expiresAtNS
            )
        case let .express(expression):
            intent = .express(
                requestID: request.requestID,
                expression: expression,
                expiresAtNS: request.lease.expiresAtNS
            )
        case .registerTarget, .removeTarget, .setAttentionPolicy, .release:
            return nil
        }

        let fingerprint = fingerprint(intent)
        guard fingerprint != lastFingerprint else { return nil }
        lastFingerprint = fingerprint
        return intent
    }

    private func groundedTargetIntent(
        requestID: String,
        targetReference: String,
        motionStyle: EmbodimentMotionStyle,
        reacquireIfOccluded: Bool,
        expiresAtNS: UInt64,
        snapshot: EmbodimentShadowSnapshot
    ) -> EmbodimentMotorIntent {
        guard let binding = snapshot.targetBindings.first(where: {
            $0.targetReference == targetReference
        }),
        binding.status == .bound || (reacquireIfOccluded && binding.status == .retained),
        let sceneID = binding.sceneID,
        let entity = snapshot.sceneEntities.first(where: { $0.sceneID == sceneID }),
        let bearing = entity.bearing else {
            return .suspend(
                requestID: requestID,
                reason: "target_binding_unavailable",
                expiresAtNS: expiresAtNS
            )
        }
        return .track(
            requestID: requestID,
            targetReference: targetReference,
            sceneID: sceneID,
            bearing: bearing,
            observedThisFrame: entity.observedThisFrame,
            motionStyle: motionStyle,
            expiresAtNS: expiresAtNS
        )
    }

    private func groundedCaptureIntent(
        requestID: String,
        targetReference: String,
        fieldOfViewDegrees: Double,
        expiresAtNS: UInt64,
        snapshot: EmbodimentShadowSnapshot
    ) -> EmbodimentMotorIntent {
        guard let binding = snapshot.targetBindings.first(where: {
            $0.targetReference == targetReference
        }),
        binding.status == .bound || binding.status == .retained,
        let sceneID = binding.sceneID,
        let entity = snapshot.sceneEntities.first(where: { $0.sceneID == sceneID }),
        let bearing = entity.bearing else {
            return .suspend(
                requestID: requestID,
                reason: "capture_target_binding_unavailable",
                expiresAtNS: expiresAtNS
            )
        }
        return .capture(
            requestID: requestID,
            targetReference: targetReference,
            sceneID: sceneID,
            bearing: bearing,
            fieldOfViewDegrees: fieldOfViewDegrees,
            expiresAtNS: expiresAtNS
        )
    }

    private func fingerprint(_ intent: EmbodimentMotorIntent) -> String {
        switch intent {
        case let .orient(requestID, bearing, tolerance, style, expiresAtNS, reason):
            return "orient|\(requestID)|\(bucket(bearing.azimuthDegrees))|\(bucket(bearing.elevationDegrees))|\(bucket(tolerance))|\(style.rawValue)|\(expiresAtNS)|\(reason)"
        case let .track(requestID, reference, sceneID, bearing, observed, style, expiresAtNS):
            return "track|\(requestID)|\(reference)|\(sceneID)|\(bucket(bearing.azimuthDegrees))|\(bucket(bearing.elevationDegrees))|\(observed)|\(style.rawValue)|\(expiresAtNS)"
        case let .capture(requestID, reference, sceneID, bearing, fieldOfView, expiresAtNS):
            return "capture|\(requestID)|\(reference ?? "none")|\(sceneID ?? "none")|\(bucket(bearing.azimuthDegrees))|\(bucket(bearing.elevationDegrees))|\(bucket(fieldOfView))|\(expiresAtNS)"
        case let .explore(requestID, policy, expiresAtNS):
            return "explore|\(requestID)|\(policy.mode.rawValue)|\(expiresAtNS)"
        case let .express(requestID, expression, expiresAtNS):
            return "express|\(requestID)|\(expression.rawValue)|\(expiresAtNS)"
        case let .suspend(requestID, reason, expiresAtNS):
            return "suspend|\(requestID)|\(reason)|\(expiresAtNS)"
        case let .release(requestID, reason):
            return "release|\(requestID ?? "none")|\(reason)"
        }
    }

    private func bucket(_ value: Double) -> Int {
        Int((value * 4).rounded())
    }
}

public enum CaptureAlignmentPhase: Equatable, Sendable {
    case drive
    case beginSettling
    case awaitSettling
    case capture
}

public struct CaptureAlignmentDecision: Equatable, Sendable {
    public let phase: CaptureAlignmentPhase
    public let stableSinceNS: UInt64?
}

/// Schmitt-trigger alignment gate for one-shot views. Entering the tight band
/// stops the gimbal; the wider exit band absorbs braking overshoot so a settled
/// camera does not repeatedly accelerate across one hard threshold.
public enum CaptureAlignmentHysteresis {
    public static func evaluate(
        errorDegrees: Double,
        stableSinceNS: UInt64?,
        at monotonicNS: UInt64,
        approachToleranceDegrees: Double = 2,
        exitToleranceDegrees: Double = 4.5,
        settlingMilliseconds: UInt64 = 180
    ) -> CaptureAlignmentDecision {
        guard errorDegrees.isFinite,
              approachToleranceDegrees > 0,
              exitToleranceDegrees >= approachToleranceDegrees else {
            return CaptureAlignmentDecision(phase: .drive, stableSinceNS: nil)
        }
        if let stableSinceNS {
            guard errorDegrees <= exitToleranceDegrees else {
                return CaptureAlignmentDecision(phase: .drive, stableSinceNS: nil)
            }
            let settlingNS = settlingMilliseconds.multipliedReportingOverflow(by: 1_000_000)
            let deadline = stableSinceNS.addingReportingOverflow(settlingNS.partialValue)
            guard !settlingNS.overflow, !deadline.overflow,
                  monotonicNS >= deadline.partialValue else {
                return CaptureAlignmentDecision(
                    phase: .awaitSettling,
                    stableSinceNS: stableSinceNS
                )
            }
            return CaptureAlignmentDecision(phase: .capture, stableSinceNS: stableSinceNS)
        }
        guard errorDegrees <= approachToleranceDegrees else {
            return CaptureAlignmentDecision(phase: .drive, stableSinceNS: nil)
        }
        return CaptureAlignmentDecision(phase: .beginSettling, stableSinceNS: monotonicNS)
    }
}

/// Samples a reachable atlas cell from an L1/L2 exploration distribution. The
/// policy reshapes L0's existing information-gain field; it does not bypass the
/// finite-joint route planner.
public enum CognitiveExplorationPlanner {
    public static func sample(
        cells: [SphericalAtlasCell],
        policy: ExplorationPolicyGoal,
        from pose: GimbalPose,
        kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite,
        uniform: Double
    ) -> SpatialCoverageDirection? {
        let reachable = cells.compactMap { cell -> (cell: SphericalAtlasCell, mass: Double)? in
            guard let route = GimbalVisibilityRoutePlanner.plan(
                to: cell.bearing,
                from: pose,
                kinematicEnvelope: kinematicEnvelope,
                observationPreference: .centered
            ) else { return nil }
            let distance = sphericalDistanceDegrees(
                cell.bearing,
                GimbalRelativeBearing(
                    azimuthDegrees: pose.panDegrees,
                    elevationDegrees: pose.pitchDegrees
                )
            )
            let novelty = min(max((cell.lastObservedMilliseconds ?? 90_000) / 90_000, 0), 1)
            let coverageNeed = cell.observationCount == 0
                ? 1
                : 1 / sqrt(Double(cell.observationCount + 1))
            let memoryGap = max(cell.expectedInformationGain, 1 - cell.placeFamiliarity)
            let epistemic = 0.05
                + policy.coverageStrength * coverageNeed
                + policy.noveltyStrength * novelty
                + policy.memoryGapStrength * memoryGap
            let continuity = exp(-distance / (35 + 120 * policy.motionContinuity))
            let regionMass = regionPreference(for: cell.bearing, regions: policy.regions)
            let directionMass = directionalPreference(
                for: cell.bearing,
                preferredDirections: policy.preferredDirections
            )
            let modeMass: Double
            switch policy.mode {
            case .probabilisticCoverage:
                modeMass = coverageNeed
            case .noveltySeeking:
                modeMass = novelty
            case .memoryGap:
                modeMass = memoryGap
            case .targetBiased:
                modeMass = max(directionMass, 0.05)
            case .directedSurvey:
                modeMass = max(max(regionMass, directionMass), 0.05)
            }
            let clearance = min(route.panClearanceDegrees / 20, route.pitchClearanceDegrees / 12)
            let boundaryComfort = 0.55 + 0.45 * min(max(clearance, 0), 1)
            let mass = max(0.000_001, epistemic * continuity * boundaryComfort
                * (0.25 + 0.75 * modeMass)
                * (1 + regionMass)
                * (1 + directionMass))
            return (cell, mass)
        }
        let total = reachable.reduce(0) { $0 + $1.mass }
        guard total > 0, total.isFinite else { return nil }
        let draw = min(max(uniform, 0), 1.0.nextDown) * total
        var cumulative = 0.0
        for candidate in reachable {
            cumulative += candidate.mass
            if draw < cumulative {
                return SpatialCoverageDirection(
                    bearing: candidate.cell.bearing,
                    probability: candidate.mass / total,
                    panoramaQuality: candidate.cell.panoramaQuality,
                    placeFamiliarity: candidate.cell.placeFamiliarity,
                    expectedInformationGain: candidate.cell.expectedInformationGain
                )
            }
        }
        return reachable.last.map {
            SpatialCoverageDirection(
                bearing: $0.cell.bearing,
                probability: $0.mass / total,
                panoramaQuality: $0.cell.panoramaQuality,
                placeFamiliarity: $0.cell.placeFamiliarity,
                expectedInformationGain: $0.cell.expectedInformationGain
            )
        }
    }

    private static func regionPreference(
        for bearing: GimbalRelativeBearing,
        regions: [SphericalSearchRegion]
    ) -> Double {
        regions.reduce(0) { result, region in
            let azimuth = angularDifference(bearing.azimuthDegrees, region.center.azimuthDegrees)
                / region.azimuthRadiusDegrees
            let elevation = (bearing.elevationDegrees - region.center.elevationDegrees)
                / region.elevationRadiusDegrees
            guard azimuth * azimuth + elevation * elevation <= 1 else { return result }
            return max(result, max(0, region.preference))
        }
    }

    private static func directionalPreference(
        for bearing: GimbalRelativeBearing,
        preferredDirections: [DirectionalPreference]
    ) -> Double {
        preferredDirections.reduce(0) { result, preference in
            let distanceRadians = sphericalDistanceDegrees(bearing, preference.bearing) * .pi / 180
            let kernel = exp(preference.concentration * (cos(distanceRadians) - 1))
            return result + preference.weight * kernel
        }
    }

    private static func sphericalDistanceDegrees(
        _ lhs: GimbalRelativeBearing,
        _ rhs: GimbalRelativeBearing
    ) -> Double {
        let azimuth = angularDifference(lhs.azimuthDegrees, rhs.azimuthDegrees) * .pi / 180
        let lhsElevation = lhs.elevationDegrees * .pi / 180
        let rhsElevation = rhs.elevationDegrees * .pi / 180
        let cosine = sin(lhsElevation) * sin(rhsElevation)
            + cos(lhsElevation) * cos(rhsElevation) * cos(azimuth)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    private static func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        var difference = (lhs - rhs).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }
}
