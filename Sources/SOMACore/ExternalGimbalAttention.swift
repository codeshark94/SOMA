import Foundation

/// Empirical screen-to-gimbal mapping. Signs are measured from short, explicit
/// calibration pulses; they are never assumed from a camera model.
public struct ExternalGimbalCalibration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let panSign: Double
    public let pitchSign: Double
    public let maximumPanDegreesPerSecond: Double
    public let maximumPitchDegreesPerSecond: Double
    /// Stable adapter identifier recorded with the calibration. This permits
    /// a newly supported product to use the same calibration contract before
    /// it needs a Swift enum case for product-specific semantics.
    public let deviceIdentifier: String?
    /// Legacy semantic profile retained for existing calibrations and their
    /// product-specific pose rules.
    public let deviceProfile: OBSBOTDeviceProfile?
    /// Image displacement per positive SDK-attitude axis. These are observed
    /// alongside the velocity-pulse signs and make pose-space planning
    /// profile-specific instead of inheriting another camera's convention.
    public let posePanImageSign: Double?
    public let posePitchImageSign: Double?
    /// SDK-attitude response to a positive direct-speed pulse. This is
    /// independent from how the image moves and is the only sign valid for
    /// routing toward an attitude-space waypoint.
    public let velocityPanPoseSign: Double?
    public let velocityPitchPoseSign: Double?
    /// Raw SDK attitude reported immediately before the calibration pulses.
    /// Some OBSBOT products report an unwrapped attitude, so all spatial
    /// planning is performed relative to this measured home pose.
    public let homePanDegrees: Double?
    public let homePitchDegrees: Double?

    public init(
        schemaVersion: Int = 2,
        panSign: Double,
        pitchSign: Double,
        maximumPanDegreesPerSecond: Double,
        maximumPitchDegreesPerSecond: Double,
        deviceIdentifier: String? = nil,
        deviceProfile: OBSBOTDeviceProfile? = nil,
        posePanImageSign: Double? = nil,
        posePitchImageSign: Double? = nil,
        velocityPanPoseSign: Double? = nil,
        velocityPitchPoseSign: Double? = nil,
        homePanDegrees: Double? = nil,
        homePitchDegrees: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.panSign = panSign
        self.pitchSign = pitchSign
        self.maximumPanDegreesPerSecond = maximumPanDegreesPerSecond
        self.maximumPitchDegreesPerSecond = maximumPitchDegreesPerSecond
        self.deviceIdentifier = deviceIdentifier ?? deviceProfile?.rawValue
        self.deviceProfile = deviceProfile
        self.posePanImageSign = posePanImageSign
        self.posePitchImageSign = posePitchImageSign
        self.velocityPanPoseSign = velocityPanPoseSign
        self.velocityPitchPoseSign = velocityPitchPoseSign
        self.homePanDegrees = homePanDegrees
        self.homePitchDegrees = homePitchDegrees
    }

    public var isValid: Bool {
        (schemaVersion == 1 || schemaVersion == 2)
            && abs(abs(panSign) - 1) < 0.000_001
            && abs(abs(pitchSign) - 1) < 0.000_001
            && maximumPanDegreesPerSecond > 0 && maximumPanDegreesPerSecond <= 180
            && maximumPitchDegreesPerSecond > 0 && maximumPitchDegreesPerSecond <= 90
            && Self.validOptionalSign(posePanImageSign)
            && Self.validOptionalSign(posePitchImageSign)
            && ((posePanImageSign == nil) == (posePitchImageSign == nil))
            && Self.validOptionalSign(velocityPanPoseSign)
            && Self.validOptionalSign(velocityPitchPoseSign)
            && ((velocityPanPoseSign == nil) == (velocityPitchPoseSign == nil))
            && Self.validOptionalFinite(homePanDegrees)
            && Self.validOptionalFinite(homePitchDegrees)
            && ((homePanDegrees == nil) == (homePitchDegrees == nil))
    }

    public func matches(deviceIdentifier: String) -> Bool {
        if let calibrationIdentifier = self.deviceIdentifier {
            return calibrationIdentifier == deviceIdentifier
        }
        return deviceProfile?.rawValue == deviceIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case panSign
        case pitchSign
        case maximumPanDegreesPerSecond
        case maximumPitchDegreesPerSecond
        case deviceIdentifier
        case deviceProfile
        case posePanImageSign
        case posePitchImageSign
        case velocityPanPoseSign
        case velocityPitchPoseSign
        case homePanDegrees
        case homePitchDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        panSign = try container.decode(Double.self, forKey: .panSign)
        pitchSign = try container.decode(Double.self, forKey: .pitchSign)
        maximumPanDegreesPerSecond = try container.decode(Double.self, forKey: .maximumPanDegreesPerSecond)
        maximumPitchDegreesPerSecond = try container.decode(Double.self, forKey: .maximumPitchDegreesPerSecond)
        deviceProfile = try? container.decodeIfPresent(OBSBOTDeviceProfile.self, forKey: .deviceProfile)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
            ?? deviceProfile?.rawValue
        posePanImageSign = try container.decodeIfPresent(Double.self, forKey: .posePanImageSign)
        posePitchImageSign = try container.decodeIfPresent(Double.self, forKey: .posePitchImageSign)
        velocityPanPoseSign = try container.decodeIfPresent(Double.self, forKey: .velocityPanPoseSign)
        velocityPitchPoseSign = try container.decodeIfPresent(Double.self, forKey: .velocityPitchPoseSign)
        homePanDegrees = try container.decodeIfPresent(Double.self, forKey: .homePanDegrees)
        homePitchDegrees = try container.decodeIfPresent(Double.self, forKey: .homePitchDegrees)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(panSign, forKey: .panSign)
        try container.encode(pitchSign, forKey: .pitchSign)
        try container.encode(maximumPanDegreesPerSecond, forKey: .maximumPanDegreesPerSecond)
        try container.encode(maximumPitchDegreesPerSecond, forKey: .maximumPitchDegreesPerSecond)
        try container.encodeIfPresent(deviceIdentifier, forKey: .deviceIdentifier)
        try container.encodeIfPresent(deviceProfile, forKey: .deviceProfile)
        try container.encodeIfPresent(posePanImageSign, forKey: .posePanImageSign)
        try container.encodeIfPresent(posePitchImageSign, forKey: .posePitchImageSign)
        try container.encodeIfPresent(velocityPanPoseSign, forKey: .velocityPanPoseSign)
        try container.encodeIfPresent(velocityPitchPoseSign, forKey: .velocityPitchPoseSign)
        try container.encodeIfPresent(homePanDegrees, forKey: .homePanDegrees)
        try container.encodeIfPresent(homePitchDegrees, forKey: .homePitchDegrees)
    }

    public var hasMeasuredPoseProjection: Bool {
        posePanImageSign != nil && posePitchImageSign != nil
    }

    public var hasMeasuredAttitudeFrame: Bool {
        hasMeasuredPoseProjection
            && velocityPanPoseSign != nil
            && velocityPitchPoseSign != nil
            && homePanDegrees != nil
            && homePitchDegrees != nil
    }

    public var poseProjection: GimbalPoseProjection {
        guard let posePanImageSign, let posePitchImageSign else {
            return .obsbotTiny2Lite
        }
        return GimbalPoseProjection(
            panImageSign: posePanImageSign,
            pitchImageSign: posePitchImageSign
        )
    }

    private static func validOptionalSign(_ value: Double?) -> Bool {
        guard let value else { return true }
        return abs(abs(value) - 1) < 0.000_001
    }

    private static func validOptionalFinite(_ value: Double?) -> Bool {
        value?.isFinite ?? true
    }

    /// Converts a logical attitude error into the direct-speed command that
    /// moves toward that attitude. Image-space and attitude-space directions
    /// are separate observations and must never be mixed.
    public func pitchCommand(
        forPoseError error: Double,
        projection: GimbalPoseProjection
    ) -> Double {
        if let velocityPitchPoseSign {
            return error * velocityPitchPoseSign
        }
        return error * pitchSign * projection.pitchImageSign
    }

    public func panCommand(
        forPoseError error: Double,
        projection: GimbalPoseProjection
    ) -> Double {
        if let velocityPanPoseSign {
            return error * velocityPanPoseSign
        }
        return error * panSign * projection.panImageSign
    }

    public func logicalPose(from rawPose: GimbalPose) -> GimbalPose {
        guard let homePanDegrees, let homePitchDegrees else { return rawPose }
        return GimbalPose(
            pitchDegrees: rawPose.pitchDegrees - homePitchDegrees,
            panDegrees: rawPose.panDegrees - homePanDegrees,
            monotonicNS: rawPose.monotonicNS
        )
    }

    /// Derives controller signs from the observed image displacement caused by
    /// positive pan and pitch pulses. A target must move far enough to separate
    /// a real response from detector jitter.
    public static func fromPositivePulseDisplacements(
        panImageDelta: Double,
        pitchImageDelta: Double,
        maximumPanDegreesPerSecond: Double = 180,
        maximumPitchDegreesPerSecond: Double = 90,
        deviceIdentifier: String? = nil,
        deviceProfile: OBSBOTDeviceProfile? = nil,
        panPoseDelta: Double? = nil,
        pitchPoseDelta: Double? = nil,
        homePose: GimbalPose? = nil
    ) -> ExternalGimbalCalibration? {
        guard abs(panImageDelta) >= 0.015, abs(pitchImageDelta) >= 0.015 else { return nil }
        let poseSigns: (pan: Double?, pitch: Double?)
        let velocityPoseSigns: (pan: Double?, pitch: Double?)
        switch (panPoseDelta, pitchPoseDelta) {
        case (nil, nil):
            poseSigns = (nil, nil)
            velocityPoseSigns = (nil, nil)
        case let (panDelta?, pitchDelta?):
            guard abs(panDelta) >= 0.25, abs(pitchDelta) >= 0.25 else { return nil }
            guard homePose != nil else { return nil }
            poseSigns = (
                panImageDelta * panDelta >= 0 ? 1 : -1,
                pitchImageDelta * pitchDelta >= 0 ? 1 : -1
            )
            velocityPoseSigns = (
                panDelta >= 0 ? 1 : -1,
                pitchDelta >= 0 ? 1 : -1
            )
        default:
            return nil
        }
        return ExternalGimbalCalibration(
            panSign: panImageDelta > 0 ? -1 : 1,
            pitchSign: pitchImageDelta > 0 ? -1 : 1,
            maximumPanDegreesPerSecond: maximumPanDegreesPerSecond,
            maximumPitchDegreesPerSecond: maximumPitchDegreesPerSecond,
            deviceIdentifier: deviceIdentifier,
            deviceProfile: deviceProfile,
            posePanImageSign: poseSigns.pan,
            posePitchImageSign: poseSigns.pitch,
            velocityPanPoseSign: velocityPoseSigns.pan,
            velocityPitchPoseSign: velocityPoseSigns.pitch,
            homePanDegrees: homePose?.panDegrees,
            homePitchDegrees: homePose?.pitchDegrees
        )
    }
}

public enum ExternalGimbalAttentionAction: Equatable, Sendable {
    case none
    case velocity(pitchDegreesPerSecond: Double, panDegreesPerSecond: Double)
    case hold
    case stop
}

/// Directional gimbal attitude feedback in the same logical pose frame used
/// by `GimbalRelativeBearing`.  The face servo uses it to distinguish subject
/// motion from camera motion and to begin braking before it passes the target.
public struct GimbalVelocityFeedback: Equatable, Sendable {
    public let pitchDegreesPerSecond: Double
    public let panDegreesPerSecond: Double

    public init(pitchDegreesPerSecond: Double, panDegreesPerSecond: Double) {
        self.pitchDegreesPerSecond = pitchDegreesPerSecond
        self.panDegreesPerSecond = panDegreesPerSecond
    }
}

/// World-bearing servo for a single face.  Both the face bearing and gimbal
/// pose are first projected to one control instant; the controller never
/// compares a captured face with an older physical pose.  Subject velocity is
/// then used to predict separation over the remaining actuator delay, rather
/// than being injected as an open-loop motor command.
private struct FaceServoDynamics: Sendable {
    private var sceneID: String?
    private var rect: NormalizedRect?
    private var referenceBearing: GimbalRelativeBearing?
    private var referenceBearingNS: UInt64?
    private var filteredTargetVelocity = GimbalVelocityFeedback(
        pitchDegreesPerSecond: 0,
        panDegreesPerSecond: 0
    )
    private var panAxis = FaceServoAxis()
    private var pitchAxis = FaceServoAxis()

    mutating func command(
        for target: AttentionTarget,
        calibration: ExternalGimbalCalibration,
        maximumPitch: Double,
        maximumPan: Double,
        bearing: GimbalRelativeBearing?,
        faceObservationNS: UInt64?,
        currentPose: GimbalPose?,
        currentVelocity: GimbalVelocityFeedback?,
        poseProjection: GimbalPoseProjection,
        at monotonicNS: UInt64
    ) -> (pitch: Double, pan: Double) {
        let continuesTrajectory = sceneID == target.id
            || rect.map { isGeometricallyContinuous($0, target.rect) } == true
            || spatiallyContinuous(with: bearing)
        if !continuesTrajectory { reset() }
        sceneID = target.id
        rect = target.rect
        let observationNS = min(faceObservationNS ?? monotonicNS, monotonicNS)
        let targetVelocity = updateTargetVelocity(with: bearing, at: observationNS)
        let errors: (pan: Double, pitch: Double)
        let physicalReference = bearing.flatMap { bearing in
            currentPose.map { pose in
                let targetAgeSeconds = seconds(from: observationNS, to: monotonicNS)
                let poseAgeSeconds = seconds(from: pose.monotonicNS, to: monotonicNS)
                let targetAtControl = GimbalRelativeBearing(
                    azimuthDegrees: bearing.azimuthDegrees + targetVelocity.panDegreesPerSecond * targetAgeSeconds,
                    elevationDegrees: bearing.elevationDegrees + targetVelocity.pitchDegreesPerSecond * targetAgeSeconds
                )
                let cameraAtControl = GimbalPose(
                    pitchDegrees: pose.pitchDegrees + (currentVelocity?.pitchDegreesPerSecond ?? 0) * poseAgeSeconds,
                    panDegrees: pose.panDegrees + (currentVelocity?.panDegreesPerSecond ?? 0) * poseAgeSeconds,
                    monotonicNS: monotonicNS
                )
                return (targetAtControl, cameraAtControl, poseAgeSeconds)
            }
        }
        if let physicalReference {
            errors = (
                pan: angularDifference(physicalReference.0.azimuthDegrees, physicalReference.1.panDegrees),
                pitch: physicalReference.0.elevationDegrees - physicalReference.1.pitchDegrees
            )
        } else {
            errors = (pan: target.rect.centerX - 0.5, pitch: target.rect.centerY - 0.5)
        }
        let panTuning = physicalReference == nil
            ? (proportionalGain: 150.0, derivativeGain: 15.0, settlingError: 0.07)
            : (proportionalGain: 3.2, derivativeGain: 0.24, settlingError: 1.4)
        let pitchTuning = physicalReference == nil
            ? (proportionalGain: 60.0, derivativeGain: 6.0, settlingError: 0.15)
            : (proportionalGain: 2.6, derivativeGain: 0.20, settlingError: 2.8)
        let actuationHorizonSeconds = physicalReference.map {
            // One control interval plus the measured feedback age approximates
            // the portion of motion that is already in flight.  Clamping
            // prevents a sparse attitude sample from becoming an aggressive
            // extrapolation.
            min(0.18, max(0.11, 0.08 + 0.5 * $0.2))
        } ?? 0
        let rawPan = panAxis.command(
            error: errors.pan,
            proportionalGain: panTuning.proportionalGain,
            derivativeGain: panTuning.derivativeGain,
            settlingError: panTuning.settlingError,
            maximum: maximumPan,
            maximumAcceleration: 260,
            targetDegreesPerSecond: targetVelocity.panDegreesPerSecond,
            measuredDegreesPerSecond: currentVelocity?.panDegreesPerSecond ?? 0,
            actuationHorizonSeconds: actuationHorizonSeconds,
            at: monotonicNS
        )
        let rawPitch = pitchAxis.command(
            error: errors.pitch,
            proportionalGain: pitchTuning.proportionalGain,
            derivativeGain: pitchTuning.derivativeGain,
            settlingError: pitchTuning.settlingError,
            maximum: maximumPitch,
            maximumAcceleration: 120,
            targetDegreesPerSecond: targetVelocity.pitchDegreesPerSecond,
            measuredDegreesPerSecond: currentVelocity?.pitchDegreesPerSecond ?? 0,
            actuationHorizonSeconds: actuationHorizonSeconds,
            at: monotonicNS
        )
        // A physical bearing is expressed in the gimbal's measured attitude
        // frame.  Its direct motor sign comes from the velocity pulse, not
        // from the screen displacement sign used by image-only tracking.
        let pan = physicalReference == nil
            ? rawPan * calibration.panSign
            : calibration.panCommand(forPoseError: rawPan, projection: poseProjection)
        let pitch = physicalReference == nil
            ? rawPitch * calibration.pitchSign
            : calibration.pitchCommand(forPoseError: rawPitch, projection: poseProjection)
        return (pitch, pan)
    }

    mutating func reset() {
        sceneID = nil
        rect = nil
        referenceBearing = nil
        referenceBearingNS = nil
        filteredTargetVelocity = GimbalVelocityFeedback(
            pitchDegreesPerSecond: 0,
            panDegreesPerSecond: 0
        )
        panAxis.reset()
        pitchAxis.reset()
    }

    private mutating func updateTargetVelocity(
        with next: GimbalRelativeBearing?,
        at monotonicNS: UInt64
    ) -> GimbalVelocityFeedback {
        defer {
            if let next {
                referenceBearing = next
                referenceBearingNS = monotonicNS
            }
        }
        guard let prior = referenceBearing,
              let referenceBearingNS,
              let next,
              monotonicNS > referenceBearingNS,
              monotonicNS - referenceBearingNS <= 250_000_000 else {
            return filteredTargetVelocity
        }
        let elapsed = Double(monotonicNS - referenceBearingNS) / 1_000_000_000
        guard elapsed >= 0.012 else { return filteredTargetVelocity }
        let instantaneous = GimbalVelocityFeedback(
            pitchDegreesPerSecond: (next.elevationDegrees - prior.elevationDegrees) / elapsed,
            panDegreesPerSecond: angularDifference(next.azimuthDegrees, prior.azimuthDegrees) / elapsed
        )
        // Angular bearing measurements can jump when a detector switches
        // boxes. Keep the velocity useful for rapid human movement without
        // letting one geometric outlier become a full-speed motor pulse.
        filteredTargetVelocity = GimbalVelocityFeedback(
            pitchDegreesPerSecond: boundedRate(
                0.45 * instantaneous.pitchDegreesPerSecond
                    + 0.55 * filteredTargetVelocity.pitchDegreesPerSecond
            ),
            panDegreesPerSecond: boundedRate(
                0.45 * instantaneous.panDegreesPerSecond
                    + 0.55 * filteredTargetVelocity.panDegreesPerSecond
            )
        )
        return filteredTargetVelocity
    }

    private func boundedRate(_ value: Double) -> Double {
        max(-120, min(120, value))
    }

    private func seconds(from earlier: UInt64, to later: UInt64) -> Double {
        guard later > earlier else { return 0 }
        return min(0.25, Double(later - earlier) / 1_000_000_000)
    }

    private func isGeometricallyContinuous(_ previous: NormalizedRect, _ next: NormalizedRect) -> Bool {
        let centerDistance = hypot(previous.centerX - next.centerX, previous.centerY - next.centerY)
        let previousArea = max(previous.width * previous.height, 0.000_1)
        let nextArea = max(next.width * next.height, 0.000_1)
        let areaRatio = nextArea / previousArea
        return centerDistance <= 0.30 && areaRatio >= 0.35 && areaRatio <= 2.8
    }

    private func spatiallyContinuous(with next: GimbalRelativeBearing?) -> Bool {
        guard let referenceBearing, let next else { return false }
        return hypot(
            angularDifference(next.azimuthDegrees, referenceBearing.azimuthDegrees),
            next.elevationDegrees - referenceBearing.elevationDegrees
        ) <= 14
    }

    private func angularDifference(_ target: Double, _ current: Double) -> Double {
        var difference = (target - current).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }

    private struct FaceServoAxis: Sendable {
        private var previousError: Double?
        private var filteredRate = 0.0
        private var command = 0.0
        private var lastNS: UInt64?

        mutating func command(
            error: Double,
            proportionalGain: Double,
            derivativeGain: Double,
            settlingError: Double,
            maximum: Double,
            maximumAcceleration: Double,
            targetDegreesPerSecond: Double,
            measuredDegreesPerSecond: Double,
            actuationHorizonSeconds: Double,
            at monotonicNS: UInt64
        ) -> Double {
            guard let previousError,
                  let lastNS,
                  monotonicNS > lastNS,
                  monotonicNS - lastNS <= 250_000_000 else {
                self.previousError = error
                filteredRate = 0
                let drive = proportionalGain * error
                command = abs(error) <= settlingError
                    ? 0
                    : bounded(drive, maximum: maximum)
                self.lastNS = monotonicNS
                return command
            }

            let elapsed = min(Double(monotonicNS - lastNS) / 1_000_000_000, 0.08)
            let instantaneousRate = (error - previousError) / elapsed
            filteredRate = 0.45 * instantaneousRate + 0.55 * filteredRate
            let relativeRate = targetDegreesPerSecond - measuredDegreesPerSecond
            // Project separation over the measured remaining actuation delay.
            // Target velocity is deliberately not added as an independent
            // command: that was an open-loop impulse which kept driving after
            // a rapidly moving person stopped, making the camera pass them.
            let projectedError = error + relativeRate * actuationHorizonSeconds
            var desired = (abs(error) <= settlingError ? 0 : proportionalGain * projectedError)
                + derivativeGain * relativeRate
            let isClosingTooFast = error * measuredDegreesPerSecond > 0
                && error * projectedError < 0
            // A reverse setpoint is physical braking only when measured
            // attitude says the gimbal would cross the target. A face box
            // moving on its own can reduce drive, but cannot reverse the
            // camera away from that still-visible person.
            if desired * error < 0 && !isClosingTooFast { desired = 0 }
            if isClosingTooFast, desired * error < 0 {
                let brakingMaximum = min(maximum * 0.45, abs(measuredDegreesPerSecond) * 0.75)
                desired = max(-brakingMaximum, min(brakingMaximum, desired))
            }
            desired = bounded(desired, maximum: maximum)
            command = slew(
                from: command,
                to: desired,
                maximumChange: maximumAcceleration * elapsed
            )
            self.previousError = error
            self.lastNS = monotonicNS
            return command
        }

        mutating func reset() {
            previousError = nil
            filteredRate = 0
            command = 0
            lastNS = nil
        }

        private func slew(from current: Double, to desired: Double, maximumChange: Double) -> Double {
            max(current - maximumChange, min(current + maximumChange, desired))
        }

        private func bounded(_ value: Double, maximum: Double) -> Double {
            max(-maximum, min(maximum, value))
        }
    }
}

/// Starts visual exploration before a session has a calibration. The bridge owns
/// the physical pulse/rest pattern and cancels it on fresh visual evidence.
public struct IdleExplorationGate: Sendable {
    private static let absenceDwellNS: UInt64 = 450_000_000
    private var noTargetSinceNS: UInt64?

    public init() {}

    public mutating func recordNoCalibratedTarget(at monotonicNS: UInt64) {
        if noTargetSinceNS == nil { noTargetSinceNS = monotonicNS }
    }

    /// The first monotonic instant at which an absence may become physical
    /// exploration. Scheduling is intentionally derived from the gate's own
    /// clock instead of duplicating this dwell in a transport timer.
    public var nextScanEligibleAtNS: UInt64? {
        noTargetSinceNS.map { $0 + Self.absenceDwellNS }
    }

    public mutating func beginIfEligible(at monotonicNS: UInt64) -> ExternalGimbalAttentionAction {
        guard let nextScanEligibleAtNS,
              monotonicNS >= nextScanEligibleAtNS else {
            return .none
        }
        return .velocity(pitchDegreesPerSecond: 0, panDegreesPerSecond: 180)
    }
}

/// Local fixation and scan policy. It has no device API; transport must enforce
/// its own watchdog and owner acknowledgements.
public struct ExternalGimbalAttentionGate: Sendable {
    private static let absenceDwellNS: UInt64 = 450_000_000
    private let calibration: ExternalGimbalCalibration
    private let autonomousScanEnabled: Bool
    private var active = false
    private var nextUpdateNS: UInt64 = 0
    private var noTargetSinceNS: UInt64?
    private var verticalTargetSignature: String?
    private var previousVerticalErrorMagnitude: Double?
    private var nonImprovingVerticalObservations = 0
    private var lastTargetWasFace = false
    private var faceServo = FaceServoDynamics()

    public init(calibration: ExternalGimbalCalibration, autonomousScanEnabled: Bool) {
        self.calibration = calibration
        self.autonomousScanEnabled = autonomousScanEnabled
    }

    /// Consume a newly completed visual observation. Predictions and audio-only
    /// belief updates must not call this method because they cannot renew motion.
    public mutating func update(
        _ belief: BeliefSnapshot,
        faceBearing: GimbalRelativeBearing? = nil,
        faceObservationNS: UInt64? = nil,
        currentPose: GimbalPose? = nil,
        currentVelocity: GimbalVelocityFeedback? = nil,
        poseProjection: GimbalPoseProjection = .identity,
        allowSocialReframing: Bool = false
    ) -> ExternalGimbalAttentionAction {
        guard calibration.isValid else { return release() }
        guard let target = belief.target, belief.targetStatus == .tracked else {
            return recordVisualLoss(at: belief.monotonicNS)
        }
        guard target.isActionEligible else {
            faceServo.reset()
            return release()
        }
        // A face can fixate. A high-confidence current body box can only make
        // the short social reframe that brings its face region into view; it
        // is never a substitute face tracker. Objects/saliency never move L0.
        let isSocialReframe = allowSocialReframing
            && target.kind == .human
            && target.label != "face"
            && target.isActionEligible
            && target.confidence >= 0.60
            && target.posteriorProbability >= 0.18
        guard target.permitsL0MotorControl || isSocialReframe else {
            faceServo.reset()
            return recordVisualLoss(at: belief.monotonicNS)
        }
        noTargetSinceNS = nil
        let faceTarget = target.isFaceMotorTarget
        if !faceTarget {
            faceServo.reset()
        }
        // A fresh face result must be able to replace a body-box correction
        // immediately. Otherwise the 10 Hz general update gate repeatedly
        // lets body observations consume the slot before the 12 Hz face pass.
        if faceTarget && !lastTargetWasFace {
            nextUpdateNS = 0
        }
        // A face can refresh at its own cadence, while a body box must wait
        // the full general interval before it can replace that eye target.
        let requiredUpdateNS = !faceTarget && lastTargetWasFace
            ? nextUpdateNS + 25_000_000
            : nextUpdateNS
        guard belief.monotonicNS >= requiredUpdateNS else { return .none }
        lastTargetWasFace = faceTarget
        // The camera returns pixels after the gimbal has already begun the
        // prior correction. A 25 Hz face controller leaves a pose-feedback
        // interval between commands instead of integrating the same stale
        // off-centre box several times.
        nextUpdateNS = belief.monotonicNS + (faceTarget ? 40_000_000 : 100_000_000)
        // The calibration caps protect hardware, not tracking quality. A face
        // box at the image edge is still a valid observation, but it must not
        // turn a brief detector jump into a full-speed eye-contact overshoot.
        let humanTarget = target.kind == .human
        let panMaximum = humanTarget
            ? min(48, calibration.maximumPanDegreesPerSecond)
            : calibration.maximumPanDegreesPerSecond
        let pitchMaximum = humanTarget
            ? min(18, calibration.maximumPitchDegreesPerSecond)
            : calibration.maximumPitchDegreesPerSecond
        if faceTarget {
            let requested = faceServo.command(
                for: target,
                calibration: calibration,
                maximumPitch: pitchMaximum,
                maximumPan: panMaximum,
                bearing: faceBearing,
                faceObservationNS: faceObservationNS,
                currentPose: currentPose,
                currentVelocity: currentVelocity,
                poseProjection: poseProjection,
                at: belief.monotonicNS
            )
            guard requested.pan != 0 || requested.pitch != 0 else {
                // Holding zero velocity is meaningful only while this gate
                // already owns an external face correction. It must remain a
                // distinct action from releasing external ownership for a
                // native-tracker handoff.
                return active ? .hold : .none
            }
            active = true
            return .velocity(pitchDegreesPerSecond: requested.pitch, panDegreesPerSecond: requested.pan)
        }

        let horizontalError = target.rect.centerX - 0.5
        let verticalError = target.stabilityMilliseconds >= 300
            ? target.rect.centerY - 0.5
            : 0
        let requestedPan = axisSpeed(
            error: horizontalError,
            // The calibration pulse is the sole authority for axis sign.
            // A moving person and the gimbal's own latency are not valid
            // evidence to reverse a physical motor mapping at runtime.
            sign: calibration.panSign,
            maximum: panMaximum,
            deadZone: 0.08,
            responseExponent: 1.25,
            minimumSpeed: 2.0
        )
        let requestedPitch = allowsVerticalCorrection(for: target, error: verticalError, deadZone: 0.12)
            ? axisSpeed(
                error: verticalError,
                sign: calibration.pitchSign,
                maximum: pitchMaximum,
                deadZone: 0.12,
                responseExponent: 1.25,
                minimumSpeed: 2.0
            )
            : 0
        let requested = (pitch: requestedPitch, pan: requestedPan)
        guard requested.pan != 0 || requested.pitch != 0 else { return release() }
        active = true
        return .velocity(pitchDegreesPerSecond: requested.pitch, panDegreesPerSecond: requested.pan)
    }

    /// Record a detector miss. This stops existing motion but deliberately keeps
    /// the scan budget; only a fresh visual target may reset that budget.
    public mutating func recordVisualLoss(at monotonicNS: UInt64) -> ExternalGimbalAttentionAction {
        if noTargetSinceNS == nil {
            noTargetSinceNS = monotonicNS
        }
        nextUpdateNS = 0
        lastTargetWasFace = false
        faceServo.reset()
        guard active else { return .none }
        active = false
        return .stop
    }

    /// Grant a search sweep after continuous visual absence. The transport owns
    /// the physical pulse/rest pattern and cancels it on the next observation.
    public var nextScanEligibleAtNS: UInt64? {
        guard autonomousScanEnabled, let noTargetSinceNS else { return nil }
        return noTargetSinceNS + Self.absenceDwellNS
    }

    public mutating func beginScanIfEligible(at monotonicNS: UInt64) -> ExternalGimbalAttentionAction {
        guard let nextScanEligibleAtNS,
              monotonicNS >= nextScanEligibleAtNS else {
            return .none
        }
        active = true
        let pan = calibration.panSign * min(120, calibration.maximumPanDegreesPerSecond)
        return .velocity(pitchDegreesPerSecond: 0, panDegreesPerSecond: pan)
    }

    /// Stop an active command without treating it as new visual evidence.
    public mutating func release() -> ExternalGimbalAttentionAction {
        nextUpdateNS = 0
        lastTargetWasFace = false
        guard active else { return .none }
        active = false
        return .stop
    }

    /// A genuine fixation should pull its box toward the image centre. If a
    /// label remains at the same vertical edge while pitch is repeatedly
    /// commanded, it is either a false detection or an incompatible axis. Do
    /// not keep driving into the ceiling/floor; retain pan and let later image
    /// evidence re-enable pitch once the error actually improves.
    private mutating func allowsVerticalCorrection(for target: AttentionTarget, error: Double, deadZone: Double) -> Bool {
        let magnitude = abs(error)
        guard magnitude > deadZone else {
            resetVerticalCorrection()
            return true
        }
        let signature = "\(target.kind.rawValue)|\(target.label ?? "unknown")|\(error < 0 ? "top" : "bottom")"
        guard signature == verticalTargetSignature else {
            verticalTargetSignature = signature
            previousVerticalErrorMagnitude = magnitude
            nonImprovingVerticalObservations = 0
            return true
        }
        defer { previousVerticalErrorMagnitude = magnitude }
        guard let previousVerticalErrorMagnitude else { return true }
        // A moving face can legitimately move farther from the image centre
        // while the gimbal catches up (for example, when a seated person
        // stands). Only an effectively stationary error is an axis-stall
        // signal; any material image-space movement reopens vertical control.
        if abs(magnitude - previousVerticalErrorMagnitude) >= 0.025 {
            nonImprovingVerticalObservations = 0
            return true
        }
        nonImprovingVerticalObservations += 1
        return nonImprovingVerticalObservations < 3
    }

    private mutating func resetVerticalCorrection() {
        verticalTargetSignature = nil
        previousVerticalErrorMagnitude = nil
        nonImprovingVerticalObservations = 0
    }

    private func axisSpeed(
        error: Double,
        sign: Double,
        maximum: Double,
        deadZone: Double,
        responseExponent: Double,
        minimumSpeed: Double
    ) -> Double {
        let magnitude = abs(error)
        guard magnitude > deadZone else { return 0 }
        let normalized = min(1, (magnitude - deadZone) / (0.5 - deadZone))
        let minimum = min(minimumSpeed, maximum)
        let speed = minimum + (maximum - minimum) * pow(normalized, responseExponent)
        return error < 0 ? -sign * speed : sign * speed
    }

}
