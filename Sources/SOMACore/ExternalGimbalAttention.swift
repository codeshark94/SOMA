import Foundation

/// Empirical screen-to-gimbal mapping. Signs are measured from short, explicit
/// calibration pulses; they are never assumed from a camera model.
public struct ExternalGimbalCalibration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let panSign: Double
    public let pitchSign: Double
    public let maximumPanDegreesPerSecond: Double
    public let maximumPitchDegreesPerSecond: Double

    public init(
        schemaVersion: Int = 1,
        panSign: Double,
        pitchSign: Double,
        maximumPanDegreesPerSecond: Double,
        maximumPitchDegreesPerSecond: Double
    ) {
        self.schemaVersion = schemaVersion
        self.panSign = panSign
        self.pitchSign = pitchSign
        self.maximumPanDegreesPerSecond = maximumPanDegreesPerSecond
        self.maximumPitchDegreesPerSecond = maximumPitchDegreesPerSecond
    }

    public var isValid: Bool {
        schemaVersion == 1
            && abs(abs(panSign) - 1) < 0.000_001
            && abs(abs(pitchSign) - 1) < 0.000_001
            && maximumPanDegreesPerSecond > 0 && maximumPanDegreesPerSecond <= 180
            && maximumPitchDegreesPerSecond > 0 && maximumPitchDegreesPerSecond <= 90
    }

    /// Converts an error in SDK attitude coordinates into the direct speed
    /// command that produces the matching image correction. The two measured
    /// mappings are both required: image-to-speed calibration and
    /// image-to-attitude projection.
    public func pitchCommand(
        forPoseError error: Double,
        projection: GimbalPoseProjection
    ) -> Double {
        error * pitchSign * projection.pitchImageSign
    }

    public func panCommand(
        forPoseError error: Double,
        projection: GimbalPoseProjection
    ) -> Double {
        error * panSign * projection.panImageSign
    }

    /// Derives controller signs from the observed image displacement caused by
    /// positive pan and pitch pulses. A target must move far enough to separate
    /// a real response from detector jitter.
    public static func fromPositivePulseDisplacements(
        panImageDelta: Double,
        pitchImageDelta: Double,
        maximumPanDegreesPerSecond: Double = 180,
        maximumPitchDegreesPerSecond: Double = 90
    ) -> ExternalGimbalCalibration? {
        guard abs(panImageDelta) >= 0.015, abs(pitchImageDelta) >= 0.015 else { return nil }
        return ExternalGimbalCalibration(
            panSign: panImageDelta > 0 ? -1 : 1,
            pitchSign: pitchImageDelta > 0 ? -1 : 1,
            maximumPanDegreesPerSecond: maximumPanDegreesPerSecond,
            maximumPitchDegreesPerSecond: maximumPitchDegreesPerSecond
        )
    }
}

public enum ExternalGimbalAttentionAction: Equatable, Sendable {
    case none
    case velocity(pitchDegreesPerSecond: Double, panDegreesPerSecond: Double)
    case hold
    case stop
}

/// Image-space PD controller for a single face. Position drives the camera
/// toward the optical centre; measured image velocity only removes drive while
/// the error is already closing. This keeps the servo responsive to a person
/// moving away without letting the camera's own delayed motion create a second
/// steering target.
private struct FaceServoDynamics: Sendable {
    private var sceneID: String?
    private var rect: NormalizedRect?
    private var referenceBearing: GimbalRelativeBearing?
    private var panAxis = FaceServoAxis()
    private var pitchAxis = FaceServoAxis()

    mutating func command(
        for target: AttentionTarget,
        calibration: ExternalGimbalCalibration,
        maximumPitch: Double,
        maximumPan: Double,
        bearing: GimbalRelativeBearing?,
        currentPose: GimbalPose?,
        poseProjection: GimbalPoseProjection,
        at monotonicNS: UInt64
    ) -> (pitch: Double, pan: Double) {
        let continuesTrajectory = sceneID == target.id
            || rect.map { isGeometricallyContinuous($0, target.rect) } == true
            || spatiallyContinuous(with: bearing)
        if !continuesTrajectory {
            panAxis.reset()
            pitchAxis.reset()
        }
        sceneID = target.id
        rect = target.rect
        if let bearing { referenceBearing = bearing }
        let errors: (pan: Double, pitch: Double)
        let physicalReference = bearing.flatMap { bearing in
            currentPose.map { pose in (bearing, pose) }
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
        let pan = panAxis.command(
            error: errors.pan,
            proportionalGain: panTuning.proportionalGain,
            derivativeGain: panTuning.derivativeGain,
            settlingError: panTuning.settlingError,
            maximum: maximumPan,
            maximumAcceleration: 260,
            at: monotonicNS
        ) * (physicalReference == nil ? calibration.panSign : calibration.panSign * poseProjection.panImageSign)
        let pitch = pitchAxis.command(
            error: errors.pitch,
            proportionalGain: pitchTuning.proportionalGain,
            derivativeGain: pitchTuning.derivativeGain,
            settlingError: pitchTuning.settlingError,
            maximum: maximumPitch,
            maximumAcceleration: 120,
            at: monotonicNS
        ) * (physicalReference == nil ? calibration.pitchSign : calibration.pitchSign * poseProjection.pitchImageSign)
        return (pitch, pan)
    }

    mutating func reset() {
        sceneID = nil
        rect = nil
        referenceBearing = nil
        panAxis.reset()
        pitchAxis.reset()
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
            at monotonicNS: UInt64
        ) -> Double {
            guard let previousError,
                  let lastNS,
                  monotonicNS > lastNS,
                  monotonicNS - lastNS <= 250_000_000 else {
                self.previousError = error
                filteredRate = 0
                command = abs(error) <= settlingError
                    ? 0
                    : max(-maximum, min(maximum, proportionalGain * error))
                self.lastNS = monotonicNS
                return command
            }

            let elapsed = min(Double(monotonicNS - lastNS) / 1_000_000_000, 0.08)
            let instantaneousRate = (error - previousError) / elapsed
            filteredRate = 0.45 * instantaneousRate + 0.55 * filteredRate
            var desired = abs(error) <= settlingError
                ? 0
                : proportionalGain * error + derivativeGain * filteredRate
            // The derivative term is braking only. While a face is still on
            // one side of centre, a camera command may slow to zero but never
            // reverse and push that face farther out of frame.
            if desired * error < 0 { desired = 0 }
            desired = max(-maximum, min(maximum, desired))
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
    }
}

/// Starts visual exploration before a session has a calibration. The bridge owns
/// the physical pulse/rest pattern and cancels it on fresh visual evidence.
public struct IdleExplorationGate: Sendable {
    private var noTargetSinceNS: UInt64?

    public init() {}

    public mutating func recordNoCalibratedTarget(at monotonicNS: UInt64) {
        if noTargetSinceNS == nil { noTargetSinceNS = monotonicNS }
    }

    public mutating func beginIfEligible(at monotonicNS: UInt64) -> ExternalGimbalAttentionAction {
        guard let noTargetSinceNS,
              monotonicNS >= noTargetSinceNS + 450_000_000 else {
            return .none
        }
        return .velocity(pitchDegreesPerSecond: 0, panDegreesPerSecond: 180)
    }
}

/// Local fixation and scan policy. It has no device API; transport must enforce
/// its own watchdog and owner acknowledgements.
public struct ExternalGimbalAttentionGate: Sendable {
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
        currentPose: GimbalPose? = nil,
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
                currentPose: currentPose,
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
    public mutating func beginScanIfEligible(at monotonicNS: UInt64) -> ExternalGimbalAttentionAction {
        guard autonomousScanEnabled,
              let noTargetSinceNS,
              monotonicNS >= noTargetSinceNS + 450_000_000 else {
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
