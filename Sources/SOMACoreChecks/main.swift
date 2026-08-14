import Foundation
import SOMACore

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("soma-core-check: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private func rect(_ x: Double) -> NormalizedRect {
    NormalizedRect(x: x, y: 0.25, width: 0.20, height: 0.30)
}

let model = PredictiveWorldModel()
let start: UInt64 = 1_000_000_000
_ = model.ingestVisual(VisualObservation(rect: rect(0.30), confidence: 0.95, source: .neuralFaceDetector), at: start)
_ = model.ingestVisual(VisualObservation(rect: rect(0.40), confidence: 0.95, source: .tracker), at: start + 100_000_000)
let voiced = model.ingestVoice(active: true, confidence: 0.95, at: start + 120_000_000)
require(voiced.targetStatus == .tracked, "visual target was not retained")
require(voiced.readyProbability > voiced.observingProbability, "voice did not prepare interaction")
require(voiced.policy == .handoffCandidate, "ready interaction did not emit handoff candidate")

let predicted = model.snapshot(at: start + 300_000_000)
require((predicted.target?.velocityX ?? 0) > 0, "target velocity was not predicted")
let probabilitySum = predicted.idleProbability + predicted.observingProbability + predicted.readyProbability
require(abs(probabilitySum - 1) < 0.000_001, "interaction probabilities do not normalize")

let lost = model.snapshot(at: start + 2_000_000_000)
require(lost.targetStatus == .none, "stale target was not discarded")
require(lost.policy == .hold, "loss did not return a safe hold policy")

let reordered = PredictiveWorldModel()
let first = reordered.ingestVisual(VisualObservation(rect: rect(0.25), confidence: 0.90, source: .neuralFaceDetector), at: start + 100_000_000)
let delayed = reordered.ingestVisual(VisualObservation(rect: rect(0.20), confidence: 0.90, source: .tracker), at: start + 50_000_000)
require(delayed.monotonicNS == start + 100_000_000, "out-of-order evidence reversed belief time")
require(delayed.target?.rect == first.target?.rect, "out-of-order evidence changed belief content")

let asynchronousFusion = PredictiveWorldModel()
_ = asynchronousFusion.ingestVoice(active: false, confidence: 0, at: start + 200_000_000)
let delayedVisionTime = start + 150_000_000
let alignedVisionTime = max(delayedVisionTime, asynchronousFusion.snapshot(at: delayedVisionTime).monotonicNS)
let alignedVisual = asynchronousFusion.ingestVisual(
    VisualObservation(rect: rect(0.65), confidence: 0.8, source: .systemSaliency),
    at: alignedVisionTime
)
require(alignedVisual.targetStatus == .tracked, "a Vision result behind audio time was dropped instead of merged")

let audioOnly = PredictiveWorldModel()
let auditoryCue = audioOnly.ingestAudioDirection(.right, confidence: 0.90, at: start)
require(auditoryCue.attentionCue.route == .auditory, "audio-only evidence did not create an auditory cue")
require(auditoryCue.attentionCue.direction == .right, "audio-only cue lost its direction")
require(auditoryCue.policy == .reacquire, "audio-only cue did not request safe reacquisition")
let expiredAuditoryCue = audioOnly.snapshot(at: start + 2_000_000_000)
require(expiredAuditoryCue.attentionCue.route == .idle, "auditory cue did not decay to idle")

let fusion = PredictiveWorldModel()
_ = fusion.ingestVisual(VisualObservation(rect: rect(0.10), confidence: 0.75, source: .neuralFaceDetector), at: start)
let fusedCue = fusion.ingestAudioDirection(.left, confidence: 0.80, at: start + 20_000_000)
require(fusedCue.attentionCue.route == .audiovisual, "matching visual and audio evidence did not fuse")
require(fusedCue.attentionCue.direction == .left, "fused cue lost its shared direction")
let weakMismatch = fusion.ingestAudioDirection(.right, confidence: 0.80, at: start + 40_000_000)
require(weakMismatch.attentionCue.route == .visual, "weak conflicting audio replaced a credible visual target")
require(weakMismatch.targetStatus == .tracked, "conflicting audio discarded the visual target")
let strongMismatch = fusion.ingestAudioDirection(.right, confidence: 1.0, at: start + 60_000_000)
require(strongMismatch.attentionCue.route == .auditory, "strong conflicting audio did not become a reacquisition cue")
require(strongMismatch.policy == .reacquire, "strong conflicting audio did not request safe reacquisition")
require(strongMismatch.targetStatus == .tracked, "strong audio cue switched identity without visual evidence")
require(strongMismatch.schemaVersion == 2, "audiovisual belief did not use the versioned schema")

let voiceGate = VoiceActivityGate()
let quiet: UInt64 = 4_000_000_000
require(!voiceGate.ingest(levelDB: -45, durationNS: 16_000_000, continuous: false, at: quiet).active, "quiet room noise opened voice gate")
require(!voiceGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 16_000_000).active, "voice gate opened without onset confirmation")
require(!voiceGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 32_000_000).active, "voice gate opened before 96ms")
require(!voiceGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 48_000_000).active, "voice gate opened before 96ms")
require(!voiceGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 64_000_000).active, "voice gate opened before 96ms")
require(!voiceGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 80_000_000).active, "voice gate opened before 96ms")
require(voiceGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 96_000_000).active, "sustained voice did not open gate")
require(voiceGate.ingest(levelDB: -60, durationNS: 16_000_000, continuous: true, at: quiet + 400_000_000).active, "voice gate closed before hangover")
require(!voiceGate.ingest(levelDB: -60, durationNS: 16_000_000, continuous: true, at: quiet + 700_000_000).active, "voice gate did not close after hangover")

let durationGate = VoiceActivityGate()
require(!durationGate.ingest(levelDB: -20, durationNS: 48_000_000, continuous: false, at: quiet).active, "voice gate opened before 96ms of audio")
require(!durationGate.ingest(levelDB: -20, durationNS: 32_000_000, continuous: true, at: quiet + 48_000_000).active, "voice gate counted callbacks instead of audio duration")
require(durationGate.ingest(levelDB: -20, durationNS: 16_000_000, continuous: true, at: quiet + 80_000_000).active, "voice gate did not accumulate audio duration")

let discontinuousGate = VoiceActivityGate()
require(!discontinuousGate.ingest(levelDB: -20, durationNS: 48_000_000, continuous: false, at: quiet).active, "voice gate opened before 96ms")
require(!discontinuousGate.ingest(levelDB: -20, durationNS: 48_000_000, continuous: false, at: quiet + 80_000_000).active, "voice gate bridged an audio discontinuity")
require(discontinuousGate.ingest(levelDB: -20, durationNS: 48_000_000, continuous: true, at: quiet + 128_000_000).active, "voice gate did not resume after continuous audio")

var stereoSource: [Float] = []
for index in 0..<512 {
    let phase = Double(index)
    let sample = sin(phase * 0.19) + cos(phase * 0.071) + Double((index * 17) % 13) / 20
    stereoSource.append(Float(sample))
}
let rightDelayed = (0..<512).map { index in index >= 3 ? stereoSource[index - 3] : 0 }
let rightAdvanced = (0..<512).map { index in index + 3 < stereoSource.count ? stereoSource[index + 3] : 0 }
var rightFractionalDelayed: [Float] = []
for index in 0..<512 {
    if index >= 3 {
        rightFractionalDelayed.append((stereoSource[index - 2] + stereoSource[index - 3]) / 2)
    } else {
        rightFractionalDelayed.append(0)
    }
}
let leftMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: rightDelayed, sampleRateHz: 32_000)
let centerMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: stereoSource, sampleRateHz: 32_000)
let rightMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: rightAdvanced, sampleRateHz: 32_000)
let fractionalMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: rightFractionalDelayed, sampleRateHz: 32_000)
require(leftMeasurement?.lagSamples == 3, "TDOA did not recover a delayed right channel")
require(centerMeasurement?.lagSamples == 0, "TDOA did not recover a centered source")
require(rightMeasurement?.lagSamples == -3, "TDOA did not recover an advanced right channel")
require(abs((fractionalMeasurement?.fractionalLagSamples ?? 0) - 2.5) < 0.20, "sub-sample TDOA did not recover a fractional delay")
require((fractionalMeasurement?.zeroLagCorrelation ?? 1) < (fractionalMeasurement?.correlation ?? 0), "fractional delay did not distinguish zero-lag channel similarity")
let periodicStereo = (0..<512).map { index in Float(index.isMultiple(of: 2) ? 1 : -1) }
require(StereoTDOAEstimator.measure(left: periodicStereo, right: periodicStereo, sampleRateHz: 32_000) == nil, "ambiguous periodic stereo signal produced a direction")
require(
    StereoTDOAEstimator.assess(left: periodicStereo, right: periodicStereo, sampleRateHz: 32_000) == .rejected(.ambiguousPeak),
    "ambiguous TDOA rejection was not diagnosable"
)
require(
    StereoTDOAEstimator.assess(left: [], right: [], sampleRateHz: 32_000) == .rejected(.invalidInput),
    "invalid TDOA input was not diagnosable"
)
let calibration = StereoDirectionCalibration.make(
    sampleRateHz: 32_000,
    left: Array(repeating: leftMeasurement!, count: 3),
    center: Array(repeating: centerMeasurement!, count: 3),
    right: Array(repeating: rightMeasurement!, count: 3)
)
require(calibration != nil, "calibration rejected stable labelled TDOA measurements")
var calibrationDiagnostics = TDOACalibrationDiagnostics()
for _ in 0..<3 {
    calibrationDiagnostics.record(position: .left, outcome: .measurement(leftMeasurement!))
    calibrationDiagnostics.record(position: .center, outcome: .measurement(centerMeasurement!))
    calibrationDiagnostics.record(position: .right, outcome: .measurement(rightMeasurement!))
}
calibrationDiagnostics.record(
    position: .left,
    outcome: .measurement(StereoTDOAMeasurement(sampleRateHz: 32_000, lagSamples: 2, correlation: 0.30))
)
calibrationDiagnostics.record(position: .left, outcome: .rejected(.ambiguousPeak))
calibrationDiagnostics.record(position: .left, outcome: .rejected(.lowEnergy))
calibrationDiagnostics.record(position: .left, outcome: .rejected(.invalidInput))
let leftDiagnostic = calibrationDiagnostics.diagnostic(for: .left)
require(leftDiagnostic.attempts == 7, "calibration diagnostic lost attempts")
require(leftDiagnostic.accepted == 4 && leftDiagnostic.eligible == 3, "calibration diagnostic mixed accepted and eligible samples")
require(leftDiagnostic.medianLagSamples == 3, "calibration diagnostic lost the eligible median lag")
require(abs((leftDiagnostic.medianFractionalLagSamples ?? 0) - (leftMeasurement?.fractionalLagSamples ?? 0)) < 0.001, "calibration diagnostic lost the fractional median lag")
require((leftDiagnostic.medianZeroLagCorrelation ?? 0) < 1, "calibration diagnostic lost zero-lag channel similarity")
require(leftDiagnostic.ambiguous == 1 && leftDiagnostic.lowEnergy == 1 && leftDiagnostic.invalidInput == 1, "calibration diagnostic lost rejection reasons")
require(calibrationDiagnostics.makeCalibration() != nil, "diagnostics could not produce a valid three-position calibration")
let uncalibratedDirection = StereoTDOAEstimator(calibration: nil).estimate(left: stereoSource, right: rightDelayed, sampleRateHz: 32_000)
require(uncalibratedDirection.direction == .unknown, "uncalibrated TDOA emitted a direction")
let calibratedEstimator = StereoTDOAEstimator(calibration: calibration)
require(calibratedEstimator.estimate(left: stereoSource, right: rightDelayed, sampleRateHz: 32_000).direction == AudioDirection.left, "calibrated TDOA did not identify left")
require(calibratedEstimator.estimate(left: stereoSource, right: stereoSource, sampleRateHz: 32_000).direction == AudioDirection.center, "calibrated TDOA did not identify center")
require(calibratedEstimator.estimate(left: stereoSource, right: rightAdvanced, sampleRateHz: 32_000).direction == AudioDirection.right, "calibrated TDOA did not identify right")

let embodiedModel = PredictiveWorldModel()
let embodiedBelief = embodiedModel.ingestVisual(
    VisualObservation(rect: rect(0.70), confidence: 0.90, source: .neuralFaceDetector, label: "face", isActionEligible: true),
    at: start
)
let embodiedPolicy = EmbodiedAttentionPolicy()
let manualDirective = embodiedPolicy.directive(for: embodiedBelief, owner: .manual)
require(manualDirective.state == .blocked, "manual owner emitted a nonzero motion recommendation")
require(manualDirective.externalPanSpeed == 0 && !manualDirective.nativeHumanTrackingRequested, "manual owner requested camera control")
let nativeDirective = embodiedPolicy.directive(for: embodiedBelief, owner: .nativeAI)
require(nativeDirective.state == .orient, "native owner did not express off-center attention")
require(nativeDirective.nativeHumanTrackingRequested, "native owner did not request native tracking")
require(nativeDirective.externalPanSpeed == 0 && nativeDirective.externalTiltSpeed == 0, "native owner emitted direct speed control")
let externalDirective = embodiedPolicy.directive(for: embodiedBelief, owner: .external)
require(externalDirective.route == .externalVisualControl && !externalDirective.stopRequested, "external owner rejected a human target")
require(externalDirective.externalPanSpeed == 0 && externalDirective.externalTiltSpeed == 0, "external owner emitted direct speed for a human-native target")
let uncertainModel = PredictiveWorldModel()
let uncertainBelief = uncertainModel.ingestVisual(
    VisualObservation(rect: rect(0.70), confidence: 0.30, source: .neuralFaceDetector),
    at: start
)
let softenedDirective = embodiedPolicy.directive(for: uncertainBelief, owner: .external)
require(softenedDirective.state == .soften, "uncertain target did not enter soften")
require(softenedDirective.externalPanSpeed == 0 && softenedDirective.externalTiltSpeed == 0, "soften emitted direct speed control")
let objectModel = PredictiveWorldModel()
let objectBelief = objectModel.ingestVisual(
    VisualObservation(rect: rect(0.70), confidence: 0.90, source: .neuralDetector, kind: .object, label: "cup", posteriorProbability: 0.80, isActionEligible: true),
    at: start
)
require(objectBelief.target?.kind == .object && objectBelief.target?.label == "cup", "object target metadata was not retained")
let objectDirective = embodiedPolicy.directive(for: objectBelief, owner: .external)
require(objectDirective.route == .none && objectDirective.stopRequested, "ordinary object retained an L0 gimbal route")
let rejectedObjectNativeDirective = embodiedPolicy.directive(for: objectBelief, owner: .nativeAI)
require(!rejectedObjectNativeDirective.nativeHumanTrackingRequested && rejectedObjectNativeDirective.stopRequested, "native human tracking accepted an object target")
let externalCalibration = ExternalGimbalCalibration(
    panSign: 1,
    pitchSign: -1,
    maximumPanDegreesPerSecond: 8,
    maximumPitchDegreesPerSecond: 6
)
require(externalCalibration.isValid, "bounded external calibration was rejected")
require(
    ExternalGimbalCalibration.fromPositivePulseDisplacements(panImageDelta: -0.04, pitchImageDelta: 0.03)?.panSign == 1
        && ExternalGimbalCalibration.fromPositivePulseDisplacements(panImageDelta: -0.04, pitchImageDelta: 0.03)?.pitchSign == -1,
    "calibration pulse displacements did not derive controller signs"
)
require(
    ExternalGimbalCalibration.fromPositivePulseDisplacements(panImageDelta: -0.01, pitchImageDelta: 0.03) == nil,
    "calibration accepted a pan displacement within detector jitter"
)
var objectGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
require(objectGate.update(objectBelief) == .none, "default object evidence issued an L0 gimbal command")
let explicitObjectBelief = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: rect(0.70), confidence: 0.90, source: .neuralDetector,
        kind: .object, label: "cup", attentionWeight: 0.90,
        posteriorProbability: 0.80, isActionEligible: true
    ), at: start
)
require(objectGate.update(explicitObjectBelief) == .none, "top-down object evidence issued an L0 gimbal command")
require(objectGate.recordVisualLoss(at: start + 100_000_000) == .none, "non-fixating object evidence retained an L0 command")
let faceControlBelief = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: rect(0.70), confidence: 0.90, source: .neuralFaceDetector,
        kind: .human, label: "face", posteriorProbability: 0.80,
        stabilityMilliseconds: 200, isActionEligible: true
    ), at: start
)
var l0AttentionController = SubconsciousAttentionController()
let socialFixation = l0AttentionController.advance(
    belief: faceControlBelief,
    evidence: .visualObservation,
    socialFixationPermitted: true
)
require(socialFixation.state == .socialFixation, "confirmed face did not enter social fixation")
require(socialFixation.permitsNativeSocialTracking, "social fixation did not expose the native adapter")
let unverifiedFace = l0AttentionController.advance(
    belief: faceControlBelief,
    evidence: .visualObservation,
    socialFixationPermitted: false
)
require(unverifiedFace.state == .socialRetention, "unverified face entered an external reframe")
require(unverifiedFace.preservesActiveExploration, "provisional social evidence cut an active exploration trajectory")
require(!unverifiedFace.permitsExternalSocialReframing, "unverified face exposed external reframe authority")
let provisionalFace = l0AttentionController.advance(
    belief: faceControlBelief,
    evidence: .visualObservation,
    socialFixationPermitted: true,
    nativeSocialTrackingPermitted: false
)
require(provisionalFace.state == .socialFixation, "provisional face could not open bounded visual fixation")
require(!provisionalFace.permitsNativeSocialTracking, "provisional face exposed native tracking authority")
let objectAttention = l0AttentionController.advance(
    belief: objectBelief,
    evidence: .visualObservation,
    socialFixationPermitted: false
)
require(objectAttention.state == .sceneObservation, "object evidence did not remain a scene-attention state")
require(!objectAttention.permitsNativeSocialTracking, "object attention acquired native motor authority")
require(objectAttention.suppressesExploration, "observed object prematurely entered blind exploration")
require(objectAttention.preservesActiveExploration, "object scene evidence cut an already active coverage trajectory")
let sceneDwellStart: UInt64 = start + 4_000_000_000
let sceneDwellObservation = VisualObservation(
    rect: rect(0.70), confidence: 0.90, source: .neuralDetector,
    kind: .object, label: "cup", posteriorProbability: 0.50,
    sceneID: "static-cup", isActionEligible: true
)
var sceneDwellController = SubconsciousAttentionController()
let initialSceneDwell = PredictiveWorldModel().ingestVisual(sceneDwellObservation, at: sceneDwellStart)
require(
    sceneDwellController.advance(
        belief: initialSceneDwell,
        evidence: .visualObservation,
        socialFixationPermitted: false
    ).state == .sceneObservation,
    "new object did not receive an observation dwell"
)
let activeSceneDwell = PredictiveWorldModel().ingestVisual(
    sceneDwellObservation,
    at: sceneDwellStart + 450_000_000
)
require(
    sceneDwellController.advance(
        belief: activeSceneDwell,
        evidence: .visualObservation,
        socialFixationPermitted: false
    ).state == .sceneObservation,
    "object observation dwell ended before its probability-weighted boundary"
)
let elapsedSceneDwell = PredictiveWorldModel().ingestVisual(
    sceneDwellObservation,
    at: sceneDwellStart + 500_000_000
)
require(
    sceneDwellController.advance(
        belief: elapsedSceneDwell,
        evidence: .visualObservation,
        socialFixationPermitted: false
    ).state == .exploration,
    "static object pinned L0 instead of yielding to exploration"
)
let visualLossAttention = l0AttentionController.advance(
    belief: lost,
    evidence: .visualLoss,
    socialFixationPermitted: false
)
require(visualLossAttention.state == .exploration, "confirmed visual loss did not enter exploration")
let retainedSocialAttention = l0AttentionController.advance(
    belief: lost,
    evidence: .visualLoss,
    socialFixationPermitted: true
)
require(retainedSocialAttention.state == .socialRetention, "social detector gap lost its attention context")
require(!retainedSocialAttention.permitsNativeSocialTracking, "detector gap renewed native motor authority")
require(!retainedSocialAttention.suppressesExploration, "retained face identity froze the gimbal at its last pose")
let nativeTrackedSocialGap = l0AttentionController.advance(
    belief: lost,
    evidence: .visualLoss,
    socialFixationPermitted: true,
    nativeSocialTrackingActive: true
)
require(nativeTrackedSocialGap.suppressesExploration, "app detector gap released active native tracking")
var smoothExploration = SmoothExplorationDynamics()
let explorationRamp1 = smoothExploration.advance(towardPitch: 40, pan: 120, at: start)
let explorationRamp2 = smoothExploration.advance(towardPitch: 40, pan: 120, at: start + 50_000_000)
let explorationReversal = smoothExploration.advance(towardPitch: -40, pan: -120, at: start + 100_000_000)
require(
    explorationRamp1.panDegreesPerSecond == 6
        && explorationRamp2.panDegreesPerSecond == 12
        && explorationReversal.panDegreesPerSecond == 6,
    "exploration waypoint reversal stepped instead of blending through bounded acceleration"
)
require(
    SmoothExplorationDynamics.stoppingVelocity(
        errorDegrees: 2,
        maximumDegreesPerSecond: 60,
        accelerationDegreesPerSecondSquared: 120
    ) == 0
        && SmoothExplorationDynamics.stoppingVelocity(
            errorDegrees: 12,
            maximumDegreesPerSecond: 60,
            accelerationDegreesPerSecondSquared: 120
        ) < 60,
    "exploration waypoint controller did not reserve braking distance"
)
require(
    SmoothExplorationDynamics.waypointTimeoutSeconds(
        panErrorDegrees: 180,
        pitchErrorDegrees: 0
    ) == 4.5,
    "distant exploration waypoint kept the fixed timeout and could stop halfway"
)
require(
    SmoothExplorationDynamics.shouldBlendToNextWaypoint(
        panErrorDegrees: 6,
        pitchErrorDegrees: 8
    ),
    "exploration did not hand off at the look-ahead boundary"
)
require(
    !SmoothExplorationDynamics.shouldBlendToNextWaypoint(
        panErrorDegrees: 8,
        pitchErrorDegrees: 8
    ),
    "exploration handed off before entering the look-ahead radius"
)
let routeOrigin = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
let boundaryCoverageGuide = GimbalVisibilityRoutePlanner.guide(
    to: GimbalRelativeBearing(azimuthDegrees: 108, elevationDegrees: 30),
    from: routeOrigin
)
require(
    boundaryCoverageGuide != nil
        && boundaryCoverageGuide!.azimuthDegrees > 60
        && boundaryCoverageGuide!.azimuthDegrees < 110
        && boundaryCoverageGuide!.elevationDegrees > 0
        && boundaryCoverageGuide!.elevationDegrees < 24,
    "coverage planner did not choose the nearest FOV-valid joint-space guide"
)
require(
    GimbalVisibilityRoutePlanner.guide(
        to: GimbalRelativeBearing(azimuthDegrees: 170, elevationDegrees: 0),
        from: routeOrigin
    ) == nil,
    "coverage planner tried to cross a joint boundary for an unreachable target"
)
let seamSafeGuide = GimbalVisibilityRoutePlanner.guide(
    to: GimbalRelativeBearing(azimuthDegrees: -108, elevationDegrees: 0),
    from: GimbalPose(pitchDegrees: 0, panDegrees: 100, monotonicNS: start)
)
require(
    seamSafeGuide != nil && seamSafeGuide!.azimuthDegrees < 0,
    "coverage planner wrapped through the positive pan boundary"
)
require(
    externalCalibration.panCommand(forPoseError: 40, projection: .obsbotTiny2Lite) == -40
        && externalCalibration.pitchCommand(forPoseError: 20, projection: .obsbotTiny2Lite) == 20,
    "pose-space exploration did not apply the calibrated OBSBOT axis mapping"
)
var socialTrackingContinuity = VisualEvidenceContinuity(lossConfirmationMilliseconds: 1_200)
socialTrackingContinuity.recordObservation(at: start)
require(
    !socialTrackingContinuity.confirmsLoss(at: start + 1_199_000_000),
    "social tracking was released before the sustained-loss boundary"
)
require(
    socialTrackingContinuity.confirmsLoss(at: start + 1_200_000_000),
    "sustained social loss did not release tracking for exploration"
)
socialTrackingContinuity.recordObservation(at: start + 1_300_000_000)
require(
    !socialTrackingContinuity.confirmsLoss(at: start + 1_400_000_000),
    "reacquired social evidence did not reset loss continuity"
)
let personOnlyBelief = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: rect(0.70), confidence: 0.90, source: .neuralDetector,
        kind: .human, label: "person", posteriorProbability: 0.80,
        stabilityMilliseconds: 200, isActionEligible: true
    ), at: start + 100_000_000
)
var socialReframeController = SubconsciousAttentionController()
let socialReframe = socialReframeController.advance(
    belief: personOnlyBelief,
    evidence: .visualObservation,
    socialFixationPermitted: false
)
require(socialReframe.state == .socialReframing, "credible body evidence did not enter social reframing")
require(socialReframe.permitsExternalSocialReframing, "credible body evidence did not expose bounded social reframing")
var lockedBodyReframeController = SubconsciousAttentionController()
let lockedBodyReframe = lockedBodyReframeController.advance(
    belief: personOnlyBelief,
    evidence: .visualObservation,
    socialFixationPermitted: true
)
require(lockedBodyReframe.state == .socialReframing, "visible body could not help reacquire a retained face")
require(lockedBodyReframe.permitsExternalSocialReframing, "retained face suppressed bounded body-assisted reacquisition")
let activeNativeBodyObservation = lockedBodyReframeController.advance(
    belief: personOnlyBelief,
    evidence: .visualObservation,
    socialFixationPermitted: true,
    nativeSocialTrackingActive: true
)
require(activeNativeBodyObservation.state == .socialRetention, "body evidence interrupted active native face tracking")
require(!activeNativeBodyObservation.permitsExternalSocialReframing, "body evidence stole active native face-tracking authority")
var faceOnlyGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: true)
if case .velocity = faceOnlyGate.update(faceControlBelief) {
} else {
    require(false, "credible face did not begin L0 fixation")
}
require(faceOnlyGate.update(personOnlyBelief) == .stop, "person-only evidence retained a face fixation")
if case .velocity = faceOnlyGate.beginScanIfEligible(at: start + 1_600_000_000) {
} else {
    require(false, "loss of face evidence did not re-arm exploration")
}
var personOnlyNativeGate = NativeHumanTrackingGate()
require(personOnlyNativeGate.update(personOnlyBelief) == .none, "native tracker accepted a person box without face evidence")
require(personOnlyNativeGate.update(PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: rect(0.70), confidence: 0.90, source: .neuralDetector,
        kind: .human, label: "person", posteriorProbability: 0.80,
        stabilityMilliseconds: 700, isActionEligible: true
    ), at: start + 700_000_000
)) == .none, "native tracker started from person-only evidence")
var facePersonFusion = FacePersonFusion()
var faceConfirmationLease = FaceConfirmationLease()
let confirmationFace = NormalizedRect(x: 0.43, y: 0.28, width: 0.12, height: 0.14)
faceConfirmationLease.record([confirmationFace], at: start)
require(!faceConfirmationLease.permits(confirmationFace, at: start + 60_000_000), "one landmark confirmation started motor authority")
faceConfirmationLease.record([confirmationFace], at: start + 60_000_000)
require(faceConfirmationLease.permits(confirmationFace, at: start + 280_000_000), "two fresh independent face confirmations were rejected")
require(!faceConfirmationLease.permits(confirmationFace, at: start + 280_000_001), "expired independent face confirmation retained motor authority")
require(
    !faceConfirmationLease.permits(NormalizedRect(x: 0.72, y: 0.28, width: 0.12, height: 0.14), at: start + 80_000_000),
    "distant face geometry passed independent confirmation"
)
faceConfirmationLease.record([confirmationFace], at: start + 1_000_000_000)
faceConfirmationLease.record([confirmationFace], at: start + 1_221_000_000)
require(!faceConfirmationLease.permits(confirmationFace, at: start + 1_221_000_000), "stale face confirmation was reused")
faceConfirmationLease.record([confirmationFace], at: start + 1_281_000_000)
require(faceConfirmationLease.permits(confirmationFace, at: start + 1_281_000_000), "fresh confirmation did not restart after stale gap")
var faceMotorContinuityLease = FaceMotorContinuityLease()
faceMotorContinuityLease.record(confirmationFace, at: start)
require(
    faceMotorContinuityLease.permits(NormalizedRect(x: 0.46, y: 0.28, width: 0.12, height: 0.14), at: start + 500_000_000),
    "short validator gap broke geometrically continuous face motor evidence"
)
require(!faceMotorContinuityLease.permits(confirmationFace, at: start + 700_000_001), "expired face motor continuity retained authority")
require(
    !faceMotorContinuityLease.permits(NormalizedRect(x: 0.82, y: 0.28, width: 0.12, height: 0.14), at: start + 80_000_000),
    "distant face reused motor continuity"
)
var faceActivityField = SceneField(requiresFaceActivity: true)
let activityFace = VisualObservation(
    rect: NormalizedRect(x: 0.38, y: 0.35, width: 0.16, height: 0.20),
    confidence: 0.95, source: .neuralFaceDetector, kind: .human, label: "face", isActionEligible: true
)
let stablePose = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
let stationaryFaceCandidate = faceActivityField.ingest(
    [activityFace], at: start, cameraPose: stablePose, cameraSettled: true
).first
require(stationaryFaceCandidate?.isActionEligible == true, "current confirmed face evidence was discarded")
require(stationaryFaceCandidate?.faceActivityEligible == false, "stationary face started motor authority")
let singleJitterFace = VisualObservation(
    rect: NormalizedRect(x: 0.393, y: 0.35, width: 0.16, height: 0.20),
    confidence: 0.95, source: .neuralFaceDetector, kind: .human, label: "face", isActionEligible: true
)
let jitteredFaceCandidate = faceActivityField.ingest(
        [singleJitterFace], at: start + 100_000_000,
        cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 100_000_000),
        cameraSettled: true
    ).first
require(jitteredFaceCandidate?.faceActivityEligible == false, "one detector jitter started motor authority")
let activeFace = VisualObservation(
    rect: NormalizedRect(x: 0.43, y: 0.35, width: 0.16, height: 0.20),
    confidence: 0.95, source: .neuralFaceDetector, kind: .human, label: "face", isActionEligible: true
)
let activeFaceCandidate = faceActivityField.ingest(
        [activeFace], at: start + 200_000_000,
        cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 200_000_000),
        cameraSettled: true
    ).first
require(activeFaceCandidate?.isActionEligible == true, "current confirmed face evidence was discarded")
require(activeFaceCandidate?.faceActivityEligible == true, "consistent real face motion did not activate motor authority")
let expiredFaceCandidate = faceActivityField.ingest(
        [activeFace], at: start + 1_700_000_001,
        cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 1_700_000_001),
        cameraSettled: true
    ).first
require(expiredFaceCandidate?.isActionEligible == true, "current confirmed face evidence was discarded")
require(expiredFaceCandidate?.faceActivityEligible == false, "inactive face retained acquisition authority")
let fusionPerson = VisualObservation(
    rect: NormalizedRect(x: 0.20, y: 0.15, width: 0.50, height: 0.70),
    confidence: 0.85, source: .neuralDetector, kind: .human, label: "person"
)
let fusionFace = VisualObservation(
    rect: NormalizedRect(x: 0.43, y: 0.28, width: 0.12, height: 0.14),
    confidence: 0.92, source: .neuralFaceDetector, kind: .human, label: "face"
)
let fusedFrame = facePersonFusion.fuse([fusionPerson, fusionFace], at: start)
require(fusedFrame.filter { $0.label == "face" }.count == 1 && !fusedFrame.contains { $0.label == "person" }, "face-person fusion did not prefer the face geometry")
require(fusedFrame.first(where: { $0.label == "face" })?.isActionEligible == true, "corroborated face did not gain motor evidence")
let faceCadenceFrame = facePersonFusion.fuse([fusionFace], at: start + 40_000_000)
require(faceCadenceFrame.first(where: { $0.label == "face" })?.isActionEligible == true, "fresh matching face lost the bounded person corroboration lease")
let shiftedFusionPerson = VisualObservation(
    rect: NormalizedRect(x: 0.30, y: 0.15, width: 0.50, height: 0.70),
    confidence: 0.88, source: .neuralDetector, kind: .human, label: "person"
)
let bridgedFrame = facePersonFusion.fuse([shiftedFusionPerson], at: start + 80_000_000)
require(bridgedFrame.first?.source == .tracker && bridgedFrame.first?.label == "face", "person evidence did not bridge the short face-model gap")
require(bridgedFrame.first?.isActionEligible == true, "corroborated face bridge lost motor eligibility")
require(facePersonFusion.fuse([shiftedFusionPerson], at: start + 320_000_000).contains { $0.label == "face" }, "face bridge ended before its inclusive 320 ms boundary")
let expiredFusionFrame = facePersonFusion.fuse([shiftedFusionPerson], at: start + 321_000_000)
require(!expiredFusionFrame.contains { $0.label == "face" } && expiredFusionFrame.contains { $0.label == "person" }, "face bridge did not expire without a renewed face result")
let unpairedFusionFace = facePersonFusion.fuse([fusionFace], at: start + 400_000_000)
require(unpairedFusionFace.first(where: { $0.label == "face" })?.isActionEligible == false, "unpaired face incorrectly gained motor authority")
var persistentFacePersonFusion = FacePersonFusion()
_ = persistentFacePersonFusion.fuse([fusionPerson, fusionFace], at: start)
persistentFacePersonFusion.promoteValidatedFace(fusionFace.rect, at: start + 60_000_000)
let persistentBridge = persistentFacePersonFusion.fuse([shiftedFusionPerson], at: start + 1_000_000_000)
require(
    persistentBridge.first(where: { $0.label == "face" })?.isFaceVerified == true,
    "a validated face did not retain person-assisted re-acquisition"
)
let releasedPersistentBridge = persistentFacePersonFusion.fuse([], at: start + 3_001_000_000)
require(
    !releasedPersistentBridge.contains { $0.label == "face" },
    "person-assisted re-acquisition outlived continuous person absence"
)
let unstableVerticalModel = PredictiveWorldModel()
let unstableVerticalBelief = unstableVerticalModel.ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.70, y: 0.75, width: 0.20, height: 0.20),
        confidence: 0.9,
        source: .neuralFaceDetector,
        label: "face",
        stabilityMilliseconds: 0,
        isActionEligible: true
    ),
    at: start
)
var unstableVerticalGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
if case let .velocity(pitch, _) = unstableVerticalGate.update(unstableVerticalBelief) {
    require(pitch != 0, "a newly observed face waited before beginning pitch correction")
} else {
    require(false, "a newly observed face did not preserve a tracking observation")
}
let stalledVerticalModel = PredictiveWorldModel()
let stalledVerticalObservation = VisualObservation(
    rect: NormalizedRect(x: 0.70, y: 0.12, width: 0.15, height: 0.15),
    confidence: 0.90,
    source: .neuralFaceDetector,
    kind: .human,
    label: "face",
    posteriorProbability: 0.80,
    sceneID: "stalled-top-face",
    stabilityMilliseconds: 500,
    isActionEligible: true
)
var stalledVerticalGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
for update in 0..<3 {
    let belief = stalledVerticalModel.ingestVisual(
        stalledVerticalObservation,
        at: start + 2_000_000_000 + UInt64(update) * 100_000_000
    )
    if case let .velocity(pitch, _) = stalledVerticalGate.update(belief) {
        require(pitch != 0, "vertical controller stopped before observing a non-improving trend")
    } else {
        require(false, "stalled vertical target did not preserve a pan observation")
    }
}
let stalledVerticalBelief = stalledVerticalModel.ingestVisual(
    stalledVerticalObservation,
    at: start + 2_300_000_000
)
if case let .velocity(pitch, pan) = stalledVerticalGate.update(stalledVerticalBelief) {
    require(pitch != 0 && pan != 0, "a validated face lost pitch correction before leaving the frame")
} else {
    require(false, "stalled vertical target did not retain pan-only observation")
}
let movingVerticalBelief = stalledVerticalModel.ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.70, y: 0.02, width: 0.15, height: 0.15),
        confidence: 0.90,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        posteriorProbability: 0.80,
        sceneID: "stalled-top-face",
        stabilityMilliseconds: 500,
        isActionEligible: true
    ),
    at: start + 2_400_000_000
)
if case let .velocity(pitch, _) = stalledVerticalGate.update(movingVerticalBelief) {
    require(pitch != 0, "a vertically moving face could not restart a stalled pitch correction")
} else {
    require(false, "a vertically moving face lost its tracking command")
}
var scanGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: true)
require(scanGate.recordVisualLoss(at: start) == .none, "visual loss unexpectedly stopped an idle controller")
require(scanGate.beginScanIfEligible(at: start + 449_000_000) == .none, "scan started before its no-target dwell")
switch scanGate.beginScanIfEligible(at: start + 450_000_000) {
case let .velocity(pitchDegreesPerSecond: pitch, panDegreesPerSecond: pan):
    require(pitch == 0 && pan > 0 && abs(pan) <= 120, "search sweep exceeded its exploration pan cap")
default:
    require(false, "autonomous scan did not produce an initial bounded pulse")
}
require(scanGate.recordVisualLoss(at: start + 1_850_000_000) == .stop, "visual loss did not stop an active scan")
if case .velocity = scanGate.beginScanIfEligible(at: start + 6_900_000_000) {
    // Continued visual absence keeps the search loop eligible.
} else {
    require(false, "search sweep did not continue during visual absence")
}
_ = scanGate.update(faceControlBelief)
require(scanGate.recordVisualLoss(at: start + 7_000_000_000) == .stop, "fresh target did not reset scan state")
if case .velocity = scanGate.beginScanIfEligible(at: start + 8_500_000_000) {
    // A fresh visual target restarts the absence dwell for another sweep.
} else {
    require(false, "fresh target did not reset scan budget")
}
let humanCandidate = VisualObservation(rect: rect(0.25), confidence: 0.75, source: .neuralDetector, kind: .human, label: "person")
let weightedObjectCandidate = VisualObservation(rect: rect(0.70), confidence: 0.80, source: .neuralDetector, kind: .object, label: "book", attentionWeight: 0.90)
let attentionDistribution = ProbabilisticAttentionSelector.infer(candidates: [humanCandidate, weightedObjectCandidate], previousTarget: nil)
require(attentionDistribution.selected?.label == "person", "an object outranked a current human")
require(attentionDistribution.candidateProbabilities[0] > attentionDistribution.candidateProbabilities[1], "human posterior was not strictly above object posterior")
let weakestHumanCandidate = VisualObservation(rect: rect(0.25), confidence: 0, source: .neuralDetector, kind: .human, label: "person")
let strongestObjectCandidate = VisualObservation(rect: rect(0.70), confidence: 1, source: .neuralDetector, kind: .object, label: "book", attentionWeight: 1)
let boundedDominanceDistribution = ProbabilisticAttentionSelector.infer(candidates: [weakestHumanCandidate, strongestObjectCandidate], previousTarget: nil)
require(boundedDominanceDistribution.selected?.kind == .human && boundedDominanceDistribution.candidateProbabilities[0] > boundedDominanceDistribution.candidateProbabilities[1], "maximum bounded object evidence outranked a current human")
let strongerObjectCandidate = VisualObservation(rect: rect(0.70), confidence: 0.95, source: .neuralDetector, kind: .object, label: "cup")
let detectorOnlyDistribution = ProbabilisticAttentionSelector.infer(candidates: [humanCandidate, strongerObjectCandidate], previousTarget: nil)
require(detectorOnlyDistribution.selected?.label == "person", "a credible person did not outrank an unweighted object")
let faceCandidate = VisualObservation(rect: rect(0.56), confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face")
let socialDistribution = ProbabilisticAttentionSelector.infer(candidates: [humanCandidate, faceCandidate], previousTarget: nil)
require(socialDistribution.selected?.label == "face", "a detected face did not become the social fixation target")
var visualEvidenceContinuity = VisualEvidenceContinuity()
visualEvidenceContinuity.recordObservation(at: start)
require(!visualEvidenceContinuity.confirmsLoss(at: start + 249_000_000), "one detector gap was treated as visual loss")
require(visualEvidenceContinuity.confirmsLoss(at: start + 250_000_000), "continuous visual absence did not become a confirmed loss")
var actionableVisualContinuity = VisualEvidenceContinuity()
actionableVisualContinuity.recordObservation(at: start)
require(!actionableVisualContinuity.confirmsLoss(at: start + 120_000_000), "an edge candidate immediately displaced a fresh actionable target")
require(actionableVisualContinuity.confirmsLoss(at: start + 250_000_000), "edge-only evidence did not release a stale actionable target")
let explicitObjectOverFace = VisualObservation(rect: rect(0.70), confidence: 0.80, source: .neuralDetector, kind: .object, label: "book", attentionWeight: 1.0)
require(
    ProbabilisticAttentionSelector.infer(candidates: [faceCandidate, explicitObjectOverFace], previousTarget: nil).selected?.label == "face",
    "an object outranked a current face"
)
var socialAttentionLease = SocialAttentionLease()
socialAttentionLease.recordEligibleHuman(at: start)
let defaultObjectDuringSocialLease = VisualObservation(
    rect: rect(0.70), confidence: 0.95, source: .neuralDetector, kind: .object, label: "book", isActionEligible: true
)
require(
    socialAttentionLease.suppressesDefaultNonHumanAttention(candidates: [defaultObjectDuringSocialLease], at: start + 2_499_000_000),
    "a default object displaced a recently observed eligible person"
)
require(
    !socialAttentionLease.suppressesDefaultNonHumanAttention(candidates: [defaultObjectDuringSocialLease], at: start + 2_500_000_000),
    "social lease did not expire after its short detector-gap hold"
)
let explicitlyWeightedObjectDuringSocialLease = VisualObservation(
    rect: rect(0.70), confidence: 0.80, source: .neuralDetector, kind: .object, label: "book", attentionWeight: 0.10, isActionEligible: true
)
require(
    !socialAttentionLease.suppressesDefaultNonHumanAttention(candidates: [explicitlyWeightedObjectDuringSocialLease], at: start + 100_000_000),
    "explicit top-down object attention could not bypass the social lease"
)
var faceLock = FaceLockLease()
let lockedFaceRect = NormalizedRect(x: 0.42, y: 0.28, width: 0.12, height: 0.14)
faceLock.record(sceneID: "face-1", rect: lockedFaceRect, at: start)
require(faceLock.holds(sceneID: "face-1", at: start + 2_999_000_000), "face lock did not retain its face-gap continuity window")
require(
    faceLock.holds(
        sceneID: "face-2",
        rect: NormalizedRect(x: 0.46, y: 0.29, width: 0.12, height: 0.14),
        at: start + 100_000_000
    ),
    "geometrically continuous detector-ID change broke face lock"
)
require(
    !faceLock.holds(
        sceneID: "face-3",
        rect: NormalizedRect(x: 0.76, y: 0.29, width: 0.12, height: 0.14),
        at: start + 100_000_000
    ),
    "distant face replaced current face lock"
)
require(faceLock.suppressesNonHumanAttention(kind: .object, attentionWeight: 0, at: start + 100_000_000), "face lock allowed a default L0 object to interrupt social fixation")
require(!faceLock.suppressesNonHumanAttention(kind: .object, attentionWeight: 0.1, at: start + 100_000_000), "face lock blocked an explicit future top-down override")
require(faceLock.isActive(at: start + 30_000_000_000), "confirmed face lock expired without an explicit exit")
var releasedFaceLock = FaceLockLease()
releasedFaceLock.record(sceneID: "controller-fault-face", rect: lockedFaceRect, at: start)
releasedFaceLock.invalidate()
require(!releasedFaceLock.isActive(at: start + 1), "controller fault did not release face lock")
let fastMovedFaceRect = NormalizedRect(x: 0.76, y: 0.48, width: 0.12, height: 0.14)
require(
    faceLock.observe(sceneID: "face-rapid-move", rect: fastMovedFaceRect, verified: false, at: start + 200_000_000),
    "a confirmed face lock rejected a rapid current face measurement"
)
require(
    faceLock.holds(sceneID: "face-rapid-move", rect: fastMovedFaceRect, at: start + 200_000_000),
    "a confirmed face lock did not follow its rapid detector-ID transition"
)
var provisionalFaceLock = FaceLockLease(durationMilliseconds: 3_000, provisionalMilliseconds: 1_200)
provisionalFaceLock.observe(sceneID: "face-1", rect: lockedFaceRect, verified: false, at: start + 4_000_000_000)
require(provisionalFaceLock.permitsInitialMotor(at: start + 4_100_000_000), "a raw face could not make its one short re-centering correction")
require(!provisionalFaceLock.permitsMotor(at: start + 4_100_000_000), "raw face detector evidence started persistent motor authority")
require(!provisionalFaceLock.permitsInitialMotor(at: start + 5_200_000_000), "unverified face outlived its fixed re-centering window")
provisionalFaceLock.observe(sceneID: "face-1", rect: lockedFaceRect, verified: false, at: start + 4_500_000_000)
require(!provisionalFaceLock.permitsMotor(at: start + 5_200_000_000), "unverified face renewed motor authority")
provisionalFaceLock.observe(sceneID: "face-1", rect: lockedFaceRect, verified: true, at: start + 5_200_000_000)
require(!provisionalFaceLock.isProvisional(at: start + 5_200_000_000), "independent face verification did not promote provisional lock")
require(provisionalFaceLock.permitsMotor(at: start + 8_100_000_000), "verified face lock did not remain active")
require(provisionalFaceLock.permitsMotor(at: start + 35_000_000_000), "verified face lock expired during detector loss")
require(
    provisionalFaceLock.suppressesCompetingFace(
        sceneID: "false-face",
        rect: NormalizedRect(x: 0.02, y: 0.05, width: 0.60, height: 0.88),
        at: start + 5_300_000_000
    ),
    "a competing raw face could interrupt the verified face lock"
)
var staticFaceLock = FaceLockLease(durationMilliseconds: 3_000, provisionalMilliseconds: 3_000)
staticFaceLock.observe(sceneID: "static-face", rect: lockedFaceRect, verified: false, at: start + 9_000_000_000)
require(staticFaceLock.permitsInitialMotor(at: start + 9_100_000_000), "static candidate did not expose the bounded initial correction")
require(!staticFaceLock.observe(sceneID: "static-face", rect: lockedFaceRect, verified: false, at: start + 12_000_000_000), "unchanged provisional face reacquired after expiry")
require(!staticFaceLock.permitsMotor(at: start + 12_000_000_000), "rejected static face retained motor authority")
require(staticFaceLock.observe(sceneID: "static-face", rect: lockedFaceRect, verified: true, at: start + 12_050_000_000), "independently verified face could not replace rejected false candidate")
require(staticFaceLock.permitsMotor(at: start + 12_050_000_000), "verified face did not reacquire motor authority")
var unverifiedFaceRejection = UnverifiedFaceRejectionGate(confirmationMilliseconds: 700)
require(
    unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 13_000_000_000),
    "raw face candidate was rejected before the independent-verification window"
)
require(
    unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 13_699_000_000),
    "raw face candidate was rejected before the independent-verification window elapsed"
)
require(
    !unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 13_700_000_000),
    "unverified static face remained eligible after its verification window"
)
require(
    !unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 13_900_000_000),
    "rejected raw face re-entered the scene field"
)
require(
    unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: true, at: start + 13_900_000_000),
    "independently verified face could not clear a raw-face rejection"
)
require(
    unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 15_000_000_000),
    "a promoted face was reclassified as an unverified candidate"
)
require(
    unverifiedFaceRejection.isValidated(lockedFaceRect),
    "a promoted face did not retain its verification lease"
)
unverifiedFaceRejection.recordNoFace(at: start + 16_999_000_000)
require(
    unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 17_000_000_000),
    "a promoted face was discarded before continuous exit evidence"
)
unverifiedFaceRejection.recordNoFace(at: start + 19_000_000_000)
require(
    !unverifiedFaceRejection.isValidated(lockedFaceRect),
    "continuous face absence did not release a promoted face"
)
require(
    unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 19_000_000_000),
    "a face could not begin a fresh provisional observation after exit"
)
require(
    !unverifiedFaceRejection.admits(rect: lockedFaceRect, independentlyVerified: false, at: start + 19_700_000_000),
    "a departed face retained validated status after its exit window"
)
var rejectedFaceSceneField = SceneField()
let rejectedFaceObservation = VisualObservation(
    rect: lockedFaceRect,
    confidence: 0.85,
    source: .neuralFaceDetector,
    kind: .human,
    label: "face",
    isFaceVerified: false
)
require(
    rejectedFaceSceneField.ingest([rejectedFaceObservation], at: start + 14_000_000_000).contains { $0.observation.label == "face" },
    "raw face was not present before explicit rejection"
)
rejectedFaceSceneField.invalidateUnverifiedFaceTracks(matching: [lockedFaceRect])
require(
    !rejectedFaceSceneField.ingest([], at: start + 14_001_000_000).contains { $0.observation.label == "face" },
    "rejected raw face remained in the spatial scene field"
)
var transientRawFaceSceneField = SceneField()
let firstTransientRawFace = transientRawFaceSceneField
    .ingest([rejectedFaceObservation], at: start + 14_100_000_000)
    .first { $0.observation.label == "face" }
require(firstTransientRawFace != nil, "raw face was not present before a detector gap")
let transientRawFaceGap = transientRawFaceSceneField
    .ingest([], at: start + 14_200_000_000)
    .first { $0.observation.label == "face" }
require(
    transientRawFaceGap?.id == firstTransientRawFace?.id
        && transientRawFaceGap?.isActionEligible == false,
    "short raw-face gap lost identity continuity or retained motor authority"
)
let resumedTransientRawFace = transientRawFaceSceneField
    .ingest([rejectedFaceObservation], at: start + 14_210_000_000)
    .first { $0.observation.label == "face" }
require(
    resumedTransientRawFace?.id == firstTransientRawFace?.id
        && resumedTransientRawFace?.observationCount == 2,
    "raw face did not resume the same short-gap track"
)
require(
    !transientRawFaceSceneField.ingest([], at: start + 14_461_000_000).contains { $0.observation.label == "face" },
    "unverified face outlived the bounded detector-gap continuity"
)
require(attentionDistribution.selectedProbability > 0 && attentionDistribution.selectedProbability < 1, "attention selector did not produce a posterior probability")
require(abs(attentionDistribution.candidateProbabilities.reduce(attentionDistribution.noTargetProbability, +) - 1) < 0.000_001, "attention posterior did not normalize across candidates and no-target")
require(attentionDistribution.normalizedEntropy > 0 && attentionDistribution.normalizedEntropy <= 1, "attention selector did not report bounded uncertainty")
let familiarObject = VisualObservation(
    rect: rect(0.50),
    confidence: 0.90,
    source: .neuralDetector,
    kind: .object,
    label: "book",
    stabilityMilliseconds: 9_000
)
let novelObject = VisualObservation(
    rect: rect(0.72),
    confidence: 0.68,
    source: .neuralDetector,
    kind: .object,
    label: "chair"
)
require(
    ProbabilisticAttentionSelector.infer(candidates: [familiarObject, novelObject], previousTarget: nil).selected?.label == "chair",
    "a familiar object did not yield attention to novel evidence"
)
require(
    ProbabilisticAttentionSelector.infer(candidates: [familiarObject], previousTarget: nil).selected == nil,
    "a habituated object prevented no-target exploration"
)
let habituatedModel = PredictiveWorldModel()
let habituatedPrevious = habituatedModel.ingestVisual(
    VisualObservation(
        rect: rect(0.50),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "book",
        posteriorProbability: 0.80,
        sceneID: "scene-familiar",
        isActionEligible: true
    ), at: start
).target
let retainedFamiliar = VisualObservation(
    rect: rect(0.50),
    confidence: 0.90,
    source: .neuralDetector,
    kind: .object,
    label: "book",
    sceneID: "scene-familiar",
    stabilityMilliseconds: 9_000
)
require(
    ProbabilisticAttentionSelector.infer(candidates: [retainedFamiliar], previousTarget: habituatedPrevious).selected == nil,
    "continuity overrode no-target after object habituation"
)
let previousPersonModel = PredictiveWorldModel()
let previousPerson = previousPersonModel.ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.05, y: 0.30, width: 0.18, height: 0.30),
        confidence: 0.80,
        source: .neuralDetector,
        kind: .human,
        label: "person",
        posteriorProbability: 0.80,
        sceneID: "scene-person",
        isActionEligible: true
    ), at: start
).target
let farPerson = VisualObservation(
    rect: NormalizedRect(x: 0.72, y: 0.30, width: 0.18, height: 0.30),
    confidence: 0.72,
    source: .neuralDetector,
    kind: .human,
    label: "person",
    sceneID: "scene-other-person"
)
let nearbyBook = VisualObservation(
    rect: NormalizedRect(x: 0.42, y: 0.30, width: 0.20, height: 0.30),
    confidence: 0.96,
    source: .neuralDetector,
    kind: .object,
    label: "book",
    sceneID: "scene-book"
)
require(
    ProbabilisticAttentionSelector.infer(candidates: [farPerson, nearbyBook], previousTarget: previousPerson).selected?.label == "person",
    "a credible person did not retain social priority over an ordinary object"
)
var nativeHumanGate = NativeHumanTrackingGate()
let credibleHumanModel = PredictiveWorldModel()
let credibleHuman = credibleHumanModel.ingestVisual(
    VisualObservation(rect: rect(0.50), confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face", posteriorProbability: 0.80, isActionEligible: true),
    at: start
)
require(nativeHumanGate.update(credibleHuman) == .none, "native gate started before its credibility lease")
let stableHuman = credibleHumanModel.ingestVisual(
    VisualObservation(rect: rect(0.50), confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face", posteriorProbability: 0.80, isActionEligible: true),
    at: start + 160_000_000
)
require(nativeHumanGate.update(stableHuman) == .start, "native gate did not start after a credible 160ms lease")
require(nativeHumanGate.isActive, "native gate did not retain ownership between heartbeats")
require(nativeHumanGate.heartbeatIfActive(at: start + 359_000_000) == .none, "native gate renewed before 200ms")
require(nativeHumanGate.heartbeatIfActive(at: start + 360_000_000) == .heartbeat, "direct face evidence did not renew native tracking")
let renewedHuman = credibleHumanModel.ingestVisual(
    VisualObservation(rect: rect(0.50), confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face", posteriorProbability: 0.80, isActionEligible: true),
    at: start + 700_000_000
)
require(nativeHumanGate.update(renewedHuman) == .heartbeat, "native gate did not renew after the next 200ms")
let weakTrackedHuman = credibleHumanModel.ingestVisual(
    VisualObservation(rect: rect(0.50), confidence: 0.55, source: .neuralFaceDetector, kind: .human, label: "face", posteriorProbability: 0.55, isActionEligible: true),
    at: start + 900_000_000
)
require(nativeHumanGate.update(weakTrackedHuman) == .heartbeat, "one-frame face confidence dip released active native tracking")
require(nativeHumanGate.update(objectBelief) == .stop, "native gate did not stop when attention changed to an object")
require(nativeHumanGate.update(credibleHumanModel.ingestVisual(
    VisualObservation(rect: rect(0.50), confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face", posteriorProbability: 0.80, isActionEligible: true),
    at: start + 1_200_000_000
)) == .none, "native gate restarted without a new lease")
let restartedHuman = credibleHumanModel.ingestVisual(
    VisualObservation(rect: rect(0.50), confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face", posteriorProbability: 0.80, isActionEligible: true),
    at: start + 1_700_000_000
)
require(nativeHumanGate.update(restartedHuman) == .start, "native gate did not restart after a new lease")
require(nativeHumanGate.update(restartedHuman, hasVisualEvidence: false) == .stop, "native gate did not stop immediately on visual loss")
var verifiedReacquisitionGate = NativeHumanTrackingGate()
require(
    verifiedReacquisitionGate.update(credibleHuman, immediateAcquisitionPermitted: true) == .start,
    "a verified face lock could not reacquire native tracking from one fresh frame"
)
require(
    verifiedReacquisitionGate.update(credibleHuman, hasVisualEvidence: false, immediateAcquisitionPermitted: true) == .stop,
    "verified face reacquisition survived an explicit visual loss"
)
require(
    !FaceLockLease.permitsProvisionalExplorationInterception(observationCount: 1, confidence: 0.99),
    "one exploration face frame opened provisional motor authority"
)
require(
    !FaceLockLease.permitsProvisionalExplorationInterception(observationCount: 3, confidence: 0.89),
    "a weak exploration face opened provisional motor authority"
)
require(
    FaceLockLease.permitsProvisionalExplorationInterception(observationCount: 2, confidence: 0.90),
    "repeated high-confidence exploration face could not preempt coverage"
)

var sceneField = SceneField()
var wallCandidates: [SceneCandidate] = []
for frame in 0...7 {
    wallCandidates = sceneField.ingest([
        VisualObservation(
            rect: NormalizedRect(x: 0.35, y: 0.02, width: 0.06, height: 0.05),
            confidence: 0.92,
            source: .neuralDetector,
            kind: .object,
            label: "bottle"
        )
    ], at: start + UInt64(frame) * 100_000_000)
}
require(wallCandidates.count == 1, "scene field did not retain a stable detector hypothesis")
require(!wallCandidates[0].isActionEligible, "a fringe visual candidate gained motor authority")

var faceContinuityField = SceneField()
let initialFace = faceContinuityField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.18, y: 0.32, width: 0.10, height: 0.12),
        confidence: 0.96,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face"
    )
], at: start).first
let adjacentFace = faceContinuityField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.33, y: 0.32, width: 0.10, height: 0.12),
        confidence: 0.97,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face"
    )
], at: start + 80_000_000).first
require(
    initialFace?.id == adjacentFace?.id,
    "an adjacent detector frame split one moving face into a new scene track"
)
let sustainedFace = faceContinuityField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.36, y: 0.32, width: 0.10, height: 0.12),
        confidence: 0.97,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face"
    )
], at: start + 220_000_000).first
require(initialFace?.isActionEligible == true && adjacentFace?.isActionEligible == true, "a current face did not open a provisional motor response")
require(sustainedFace?.isActionEligible == true, "a current geometrically continuous face lost provisional motor eligibility")
let gappedFace = faceContinuityField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.36, y: 0.32, width: 0.10, height: 0.12),
        confidence: 0.97,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face"
    )
], at: start + 1_000_000_000).first
require(gappedFace?.isActionEligible == true, "a renewed current face did not reopen provisional motor eligibility")

var verifiedScene = SceneField()
var verifiedCandidates: [SceneCandidate] = []
for frame in 0...5 {
    verifiedCandidates = verifiedScene.ingest([
        VisualObservation(
            rect: NormalizedRect(x: 0.35, y: 0.30, width: 0.25, height: 0.25),
            confidence: 0.86,
            source: .neuralDetector,
            kind: .object,
            label: "book"
        ),
        VisualObservation(
            rect: NormalizedRect(x: 0.35, y: 0.30, width: 0.25, height: 0.25),
            confidence: 0.82,
            source: .systemSaliency,
            kind: .unknown
        )
    ], at: start + UInt64(frame) * 100_000_000,
       cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + UInt64(frame) * 100_000_000))
}
require(verifiedCandidates.count == 1, "corroborating sources did not merge into one scene track")
require(verifiedCandidates[0].isActionEligible, "stable centered corroborated object did not become action eligible")
require(verifiedCandidates[0].attentionObservation().sceneID == verifiedCandidates[0].id, "scene identity did not reach attention")

var genericScene = SceneField()
var genericCandidates: [SceneCandidate] = []
for frame in 0...2 {
    genericCandidates = genericScene.ingest([
        VisualObservation(
            rect: NormalizedRect(x: 0.64, y: 0.25, width: 0.20, height: 0.25),
            confidence: 0.72,
            source: .systemSaliency
        )
    ], at: start + UInt64(frame) * 100_000_000,
       cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + UInt64(frame) * 100_000_000))
}
require(genericCandidates.count == 1 && genericCandidates[0].isActionEligible, "stable unknown visual candidate could not become observable")
var fullFrameSaliencyField = SceneField()
let fullFrameSaliency = fullFrameSaliencyField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.05, y: 0.03, width: 0.90, height: 0.88),
        confidence: 0.80,
        source: .systemSaliency
    )
], at: start).first
require(fullFrameSaliency?.isActionEligible == false, "full-frame saliency became an active target")
let centeredTrackingBoundary = TrackingBoundary(
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86
)
require(
    centeredTrackingBoundary.contains(NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20)),
    "centered tracking boundary rejected a foveal object"
)
require(
    !centeredTrackingBoundary.contains(NormalizedRect(x: 0.01, y: 0.35, width: 0.20, height: 0.20)),
    "centered tracking boundary admitted an edge object"
)
let lowerEdgeFaceRect = NormalizedRect(x: 0.40, y: 0.82, width: 0.20, height: 0.12)
require(
    TrackingBoundary.allowsFaceLockAcquisition(NormalizedRect(x: 0.47, y: 0.67, width: 0.12, height: 0.20)),
    "a live upright face in Vision's upper image field was rejected before lock acquisition"
)
require(
    !TrackingBoundary.allowsFaceLockAcquisition(NormalizedRect(x: 0.40, y: 0.00, width: 0.20, height: 0.08)),
    "floor-edge texture was admitted to face lock acquisition"
)
require(
    !centeredTrackingBoundary.contains(lowerEdgeFaceRect)
        && centeredTrackingBoundary.allowsFaceReentry(lowerEdgeFaceRect),
    "a face just outside the conservative framing envelope could not re-enter"
)
var lowerEdgeFaceField = SceneField()
let lowerEdgeFace = lowerEdgeFaceField.ingest(
    [VisualObservation(
        rect: lowerEdgeFaceRect,
        confidence: 0.95,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        isActionEligible: true,
        isFaceVerified: true
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86
).first
require(lowerEdgeFace?.isActionEligible == true, "a confirmed lower-edge face lost re-entry authority")
let lowerEdgeFaceOffscreen = lowerEdgeFaceField.ingest(
    [],
    at: start + 300_000_000,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 300_000_000),
    horizontalFieldOfViewDegrees: 86
).first
require(lowerEdgeFaceOffscreen?.isActionEligible == false, "an offscreen face retained direct motor authority")
require(lowerEdgeFaceOffscreen?.bearing != nil, "verified face loss discarded its remembered recovery bearing")
var lowerEdgeObjectField = SceneField()
let lowerEdgeObject = lowerEdgeObjectField.ingest(
    [VisualObservation(
        rect: lowerEdgeFaceRect,
        confidence: 0.95,
        source: .neuralDetector,
        kind: .object,
        label: "edge-object"
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86
).first
require(lowerEdgeObject?.isActionEligible == false, "a lower-edge object gained face re-entry authority")
let unavailablePoseBoundary = TrackingBoundary(cameraPose: nil, horizontalFieldOfViewDegrees: 86)
require(
    !unavailablePoseBoundary.isPoseAligned
        && !unavailablePoseBoundary.allowsMotorTarget(NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20)),
    "a missing attitude sample granted motor authority"
)
var poseUnavailableSceneField = SceneField()
let poseUnavailableCandidate = poseUnavailableSceneField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "unposed-object"
    )],
    at: start
).first
require(poseUnavailableCandidate?.isActionEligible == false, "an unposed scene candidate gained motor authority")
var poseUnavailableHumanField = SceneField()
let poseUnavailableHuman = poseUnavailableHumanField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90, source: .neuralFaceDetector, kind: .human, label: "face", isActionEligible: true
    )],
    at: start
).first
require(poseUnavailableHuman?.isActionEligible == true, "a live face stopped solely because attitude feedback was briefly unavailable")
let poseUnavailableBelief = PredictiveWorldModel().ingestVisual(
    poseUnavailableCandidate!.attentionObservation(),
    at: start
)
var poseUnavailableGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
require(poseUnavailableGate.update(poseUnavailableBelief) == .none, "an unposed visual belief produced external motion")
let leftLimitTrackingBoundary = TrackingBoundary(
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: -147, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86
)
require(
    leftLimitTrackingBoundary.minimumCenterX > 0.65
        && leftLimitTrackingBoundary.contains(NormalizedRect(x: 0.70, y: 0.35, width: 0.20, height: 0.20)),
    "left pan limit did not shift the tracking boundary inward"
)
var limitSceneField = SceneField()
let limitScene = limitSceneField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.10, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "edge-object"
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: -147, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86
)
require(limitScene.first?.isActionEligible == false, "angle-dependent tracking boundary gave an outer-edge object motor authority")
var spatialSceneField = SceneField()
let spatialInitial = spatialSceneField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.88,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        isActionEligible: true,
        isFaceVerified: true
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 20, monotonicNS: start),
    horizontalFieldOfViewDegrees: 70
)
require(spatialInitial.first?.bearing != nil, "gimbal pose did not project a scene candidate into space")
let spatialReacquired = spatialSceneField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.0, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        isActionEligible: true,
        isFaceVerified: true
    )],
    at: start + 1_000_000_000,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 50, monotonicNS: start + 1_000_000_000),
    horizontalFieldOfViewDegrees: 70
)
require(spatialReacquired.count == 1 && spatialReacquired.first?.id == spatialInitial.first?.id, "spatial re-observation created a duplicate scene")
let spatialInterveningFrame = spatialSceneField.ingest([], at: start + 1_075_000_000)
require(spatialInterveningFrame.count == 1 && !spatialInterveningFrame[0].observedThisFrame, "one detector-cadence gap discarded spatial map evidence")
let spatialOffscreen = spatialSceneField.ingest([], at: start + 11_000_000_000)
require(spatialOffscreen.count == 1 && spatialOffscreen[0].observedThisFrame == false, "offscreen spatial scene was not retained")
require(
    spatialOffscreen[0].spatialConfidence == (spatialReacquired.first?.spatialConfidence ?? 0),
    "a retained human spatial hypothesis decayed before re-observation"
)
let persistentSpatialMemory = spatialSceneField.ingest([], at: start + 61_000_000_000)
require(
    persistentSpatialMemory.count == 1
        && persistentSpatialMemory[0].id == spatialInitial.first?.id
        && persistentSpatialMemory[0].lastSeenMilliseconds >= 60_000,
    "spatial scene was discarded instead of retained for the running session"
)
let refreshedSpatialMemory = spatialSceneField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.0, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.92,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        isActionEligible: true
    )
], at: start + 61_100_000_000, cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 50, monotonicNS: start + 61_100_000_000), horizontalFieldOfViewDegrees: 70)
require(
    refreshedSpatialMemory.count == 1
        && refreshedSpatialMemory[0].id == spatialInitial.first?.id
        && refreshedSpatialMemory[0].observedThisFrame
        && refreshedSpatialMemory[0].lastSeenMilliseconds == 0,
    "a revisited spatial scene did not refresh its existing session-memory entry"
)
var highElevationSpatialField = SceneField()
_ = highElevationSpatialField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "lamp"
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 60, panDegrees: 0, monotonicNS: start)
)
_ = highElevationSpatialField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "lamp"
    )],
    at: start + 100_000_000,
    cameraPose: GimbalPose(pitchDegrees: 60, panDegrees: 0, monotonicNS: start + 100_000_000)
)
let highElevationOffscreen = highElevationSpatialField.ingest([], at: start + 1_100_000_000)
require((highElevationOffscreen.first?.bearing?.elevationDegrees ?? 0) > 36, "high-elevation scene lost its spatial bearing")
var fringeSpatialField = SceneField()
var fringeCandidates: [SceneCandidate] = []
for frame in 0...2 {
    fringeCandidates = fringeSpatialField.ingest(
        [VisualObservation(
            rect: NormalizedRect(x: 0.35, y: 0.02, width: 0.06, height: 0.05),
            confidence: 0.92,
            source: .neuralDetector,
            kind: .object,
            label: "bottle"
        )],
        at: start + UInt64(frame) * 100_000_000,
        cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + UInt64(frame) * 100_000_000)
    )
}
let fringeOffscreen = fringeSpatialField.ingest([], at: start + 400_000_000)
require(fringeCandidates.first?.isActionEligible == false, "live fringe candidate gained motor authority")
require(fringeOffscreen.first?.observedThisFrame == false, "fringe hypothesis was discarded from spatial memory")
var distinctSpatialField = SceneField()
_ = distinctSpatialField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "book"
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    horizontalFieldOfViewDegrees: 70
)
let distinctSpatial = distinctSpatialField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "book"
    )],
    at: start + 1_000_000_000,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 40, monotonicNS: start + 1_000_000_000),
    horizontalFieldOfViewDegrees: 70
)
require(distinctSpatial.count == 2, "same label at a different bearing merged into one spatial scene")
let freshSpatialPose = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
require(freshSpatialPose.isFresh(for: start + 50_000_000, maximumAgeNS: 50_000_000), "capture-aligned pose was rejected")
require(!freshSpatialPose.isFresh(for: start + 50_000_001, maximumAgeNS: 50_000_000), "stale pose was accepted")
var coverageField = SpatialCoverageField()
coverageField.observe(pose: freshSpatialPose, horizontalFieldOfViewDegrees: 86, at: start)
let unexploredDirection = coverageField.nextDirection(from: freshSpatialPose, at: start + 100_000_000)
require(unexploredDirection != nil, "coverage field did not select an unexplored direction")
require(
    abs(unexploredDirection!.bearing.azimuthDegrees) > 43,
    "coverage field selected a direction already inside the current view"
)
require(abs(unexploredDirection!.bearing.elevationDegrees) <= 30, "coverage field exceeded its elevation comfort band")
let sampledCoverageDirection = coverageField.sampleNextDirection(
    from: freshSpatialPose,
    at: start + 100_000_000,
    temperature: 1.4,
    uniform: 0
)
require(sampledCoverageDirection != nil, "coverage posterior sampling did not draw a direction")
require(abs(sampledCoverageDirection!.bearing.elevationDegrees) == 30, "coverage posterior omitted its vertical exploration layers")
let sampledCoverageProbability = sampledCoverageDirection!.probability
coverageField.recordUnproductiveVisit(to: sampledCoverageDirection!)
require(
    (coverageField.sampleNextDirection(
        from: freshSpatialPose,
        at: start + 100_000_000,
        temperature: 1.4,
        uniform: 0
    )?.probability ?? 1) < sampledCoverageProbability,
    "an unproductive coverage direction did not lose posterior probability"
)
require(
    coverageField.sampleNextDirection(
        from: freshSpatialPose,
        at: start + 100_000_000,
        temperature: 1.4,
        uniform: 0.999_999
    ) == nil,
    "coverage posterior sampling omitted the no-exploration outcome"
)
var panStallRecovery = PanStallRecovery()
require(
    panStallRecovery.record(requestedPanDegreesPerSecond: 180, observedMotionDegrees: 0.1) == .reverse,
    "a first stalled pan direction did not request reversal"
)
require(
    panStallRecovery.record(requestedPanDegreesPerSecond: -180, observedMotionDegrees: 0.1) == .recenter,
    "two stalled pan directions did not request re-centering"
)
require(
    panStallRecovery.record(requestedPanDegreesPerSecond: 180, observedMotionDegrees: 2) == .none,
    "observed pan motion did not clear a stall"
)
let exploredPose = GimbalPose(
    pitchDegrees: unexploredDirection!.bearing.elevationDegrees,
    panDegrees: unexploredDirection!.bearing.azimuthDegrees,
    monotonicNS: start + 200_000_000
)
coverageField.observe(pose: exploredPose, horizontalFieldOfViewDegrees: 86, at: start + 200_000_000)
let nextUnexploredDirection = coverageField.nextDirection(from: exploredPose, at: start + 300_000_000)
require(nextUnexploredDirection?.bearing != unexploredDirection!.bearing, "coverage field remained fixated on an observed direction")
let genericModel = PredictiveWorldModel()
let genericBelief = genericModel.ingestVisual(
    VisualObservation(
        rect: genericCandidates[0].observation.rect,
        confidence: genericCandidates[0].observation.confidence,
        source: genericCandidates[0].observation.source,
        kind: .unknown,
        posteriorProbability: 0.70,
        sceneID: genericCandidates[0].id,
        stabilityMilliseconds: genericCandidates[0].stabilityMilliseconds,
        isActionEligible: true
    ), at: start + 300_000_000
)
var genericGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
require(genericGate.update(genericBelief) == .none, "default unknown evidence issued an L0 gimbal command")
var weightedSceneField = SceneField()
let weightedScene = weightedSceneField.ingest([
    VisualObservation(
        rect: NormalizedRect(x: 0.58, y: 0.30, width: 0.18, height: 0.20),
        confidence: 0.85, source: .neuralDetector, kind: .object,
        label: "book", attentionWeight: 0.90
    )
], at: start, cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start))
require(abs((weightedScene.first?.observation.attentionWeight ?? 0) - 0.90) < 0.000_001, "scene field discarded explicit top-down attention weight")
let faceModel = PredictiveWorldModel()
let faceBelief = faceModel.ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.52, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.95,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        stabilityMilliseconds: 150,
        isActionEligible: true
    ),
    at: start
)
var faceGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
if case let .velocity(pitch, pan) = faceGate.update(faceBelief) {
    require(pitch != 0 || pan != 0, "off-centre face did not request an eye-contact correction")
} else {
    require(false, "off-centre face released instead of correcting eye contact")
}
let nearFaceBelief = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.48, y: 0.40, width: 0.12, height: 0.20),
        confidence: 0.9,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        stabilityMilliseconds: 200,
        isActionEligible: true
    ),
    at: start
)
let farFaceBelief = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.78, y: 0.40, width: 0.12, height: 0.20),
        confidence: 0.9,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        stabilityMilliseconds: 200,
        isActionEligible: true
    ),
    at: start
)
var nearFaceGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
var farFaceGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
require(nearFaceGate.update(nearFaceBelief) == .none, "a centred face did not stop the pan axis")
if case let .velocity(_, farPan) = farFaceGate.update(farFaceBelief) {
    require(abs(farPan) <= 36, "face servo exceeded its live SDK-speed cap")
} else {
    require(false, "far face did not emit a tracking velocity")
}
let farPersonBelief = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.78, y: 0.40, width: 0.12, height: 0.20),
        confidence: 0.9,
        source: .neuralDetector,
        kind: .human,
        label: "person",
        stabilityMilliseconds: 300,
        isActionEligible: true
    ),
    at: start
)
var farPersonGate = ExternalGimbalAttentionGate(calibration: externalCalibration, autonomousScanEnabled: false)
require(farPersonGate.update(farPersonBelief) == .none, "person-only evidence retained an L0 fixation route")
func dynamicFaceBelief(centerX: Double, at monotonicNS: UInt64) -> BeliefSnapshot {
    PredictiveWorldModel().ingestVisual(
        VisualObservation(
            rect: NormalizedRect(x: centerX - 0.06, y: 0.40, width: 0.12, height: 0.20),
            confidence: 0.95,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
            sceneID: "stable-face",
            stabilityMilliseconds: 250,
            isActionEligible: true
        ),
        at: monotonicNS
    )
}
func dynamicFaceVerticalBelief(centerY: Double, stabilityMilliseconds: Double, at monotonicNS: UInt64) -> BeliefSnapshot {
    PredictiveWorldModel().ingestVisual(
        VisualObservation(
            rect: NormalizedRect(x: 0.44, y: centerY - 0.10, width: 0.12, height: 0.20),
            confidence: 0.95,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
            sceneID: "rising-face",
            stabilityMilliseconds: stabilityMilliseconds,
            isActionEligible: true
        ),
        at: monotonicNS
    )
}
let dynamicFaceCalibration = ExternalGimbalCalibration(
    panSign: 1,
    pitchSign: 1,
    maximumPanDegreesPerSecond: 180,
    maximumPitchDegreesPerSecond: 90
)
var dynamicFaceGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
let dynamicInitialBelief = dynamicFaceBelief(centerX: 0.58, at: start)
let dynamicJitterBelief = dynamicFaceBelief(centerX: 0.45, at: start + 80_000_000)
let initialPan: Double
switch dynamicFaceGate.update(dynamicInitialBelief) {
case let .velocity(_, pan):
    initialPan = pan
    require(initialPan >= 8, "face servo did not respond strongly enough to an off-centre face")
    require(initialPan <= 36, "face servo started above its live SDK-speed cap")
default:
    require(false, "off-centre face did not begin a correction")
    initialPan = 0
}
var adaptiveFaceGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
let adaptiveInitial = adaptiveFaceGate.update(dynamicFaceBelief(centerX: 0.58, at: start + 300_000_000))
let adaptivePersistent = adaptiveFaceGate.update(dynamicFaceBelief(centerX: 0.72, at: start + 380_000_000))
if case let .velocity(_, initialAdaptivePan) = adaptiveInitial,
   case let .velocity(_, persistentAdaptivePan) = adaptivePersistent {
    require(
        abs(persistentAdaptivePan) > abs(initialAdaptivePan),
        "a persistent face error did not adaptively increase the live drive"
    )
} else {
    require(false, "adaptive face drive did not emit both live corrections")
}
var closingFaceGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
let closingInitial = closingFaceGate.update(dynamicFaceBelief(centerX: 0.80, at: start + 390_000_000))
let closingFollowup = closingFaceGate.update(dynamicFaceBelief(centerX: 0.70, at: start + 470_000_000))
if case let .velocity(_, initialClosingPan) = closingInitial,
   case let .velocity(_, followupClosingPan) = closingFollowup {
    require(
        initialClosingPan > followupClosingPan && followupClosingPan >= 0,
        "face PD servo did not brake a rapidly closing image error"
    )
} else {
    require(false, "face PD servo did not emit the closing-error commands")
}
var poseReferencedFaceGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
let poseReferencedInitial = poseReferencedFaceGate.update(
    dynamicFaceBelief(centerX: 0.58, at: start + 480_000_000),
    faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: -8),
    currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 480_000_000)
)
let poseReferencedClosing = poseReferencedFaceGate.update(
    dynamicFaceBelief(centerX: 0.58, at: start + 560_000_000),
    faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: -8),
    currentPose: GimbalPose(pitchDegrees: -4, panDegrees: 6, monotonicNS: start + 560_000_000)
)
if case let .velocity(initialPitch, initialPan) = poseReferencedInitial,
   case let .velocity(closingPitch, closingPan) = poseReferencedClosing {
    require(initialPitch < 0 && initialPan > 0, "pose-referenced face servo did not follow the physical bearing axes")
    require(abs(closingPitch) < abs(initialPitch) && abs(closingPan) < abs(initialPan), "pose-referenced face servo did not brake as attitude reached the face bearing")
} else {
    require(false, "pose-referenced face servo did not emit physical-bearing commands")
}
var risingFaceGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
if case let .velocity(initialPitch, _) = risingFaceGate.update(
    dynamicFaceVerticalBelief(centerY: 0.22, stabilityMilliseconds: 0, at: start + 420_000_000)
) {
    require(abs(initialPitch) >= 8, "a newly observed elevated face waited before beginning pitch correction")
} else {
    require(false, "a newly observed elevated face did not begin pitch correction")
}
if case let .velocity(predictedPitch, _) = risingFaceGate.update(
    dynamicFaceVerticalBelief(centerY: 0.10, stabilityMilliseconds: 16, at: start + 500_000_000)
) {
    require(abs(predictedPitch) > 8, "outward face motion did not receive a latency-compensated pitch response")
} else {
    require(false, "outward face motion lost its pitch correction")
}
require(dynamicFaceGate.update(dynamicJitterBelief) == .hold, "face settling region did not hold the active correction before a centre crossing")
if case let .velocity(_, persistentPan) = dynamicFaceGate.update(dynamicFaceBelief(centerX: 0.30, at: start + 160_000_000)) {
    require(persistentPan < 0 && abs(persistentPan) < 25, "face servo did not slew a sustained reversal")
} else {
    require(false, "persistent face movement did not resume correction")
}
var nativeHandoffGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
_ = nativeHandoffGate.update(dynamicFaceBelief(centerX: 0.70, at: start + 200_000_000))
require(nativeHandoffGate.release() == .stop, "native handoff did not release external face ownership")
var sceneHandoffGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
_ = sceneHandoffGate.update(dynamicFaceBelief(centerX: 0.58, at: start + 500_000_000))
let nearbyDifferentScene = PredictiveWorldModel().ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.24, y: 0.40, width: 0.12, height: 0.20),
        confidence: 0.95,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        sceneID: "new-scene-id",
        stabilityMilliseconds: 250,
        isActionEligible: true
    ),
    at: start + 580_000_000
)
if case let .velocity(_, handoffPan) = sceneHandoffGate.update(nearbyDifferentScene) {
    require(abs(handoffPan) <= 60, "nearby face scene-id churn bypassed the live SDK-speed cap")
} else {
    require(false, "nearby face scene-id churn lost the active correction")
}
var panSignGate = ExternalGimbalAttentionGate(calibration: dynamicFaceCalibration, autonomousScanEnabled: false)
_ = panSignGate.update(dynamicFaceBelief(centerX: 0.75, at: start + 300_000_000))
_ = panSignGate.update(dynamicFaceBelief(centerX: 0.81, at: start + 380_000_000))
if case let .velocity(_, correctedPan) = panSignGate.update(dynamicFaceBelief(centerX: 0.88, at: start + 460_000_000)) {
    require(correctedPan > 0, "face tracking changed the calibrated pan direction at runtime")
} else {
    require(false, "calibrated pan tracking did not retain a command")
}
let bodyAfterFace = faceModel.ingestVisual(
    VisualObservation(
        rect: NormalizedRect(x: 0.60, y: 0.35, width: 0.20, height: 0.20),
        confidence: 0.95,
        source: .neuralDetector,
        kind: .human,
        label: "person",
        stabilityMilliseconds: 150,
        isActionEligible: true
    ),
    at: start + 80_000_000
)
require(faceGate.update(bodyAfterFace) == .stop, "a body box did not release the face-only fixation")
var idleExploration = IdleExplorationGate()
idleExploration.recordNoCalibratedTarget(at: start)
require(idleExploration.beginIfEligible(at: start + 449_000_000) == .none, "idle exploration began before its dwell")
if case let .velocity(pitch, pan) = idleExploration.beginIfEligible(at: start + 450_000_000) {
    require(pitch == 0 && pan == 180, "idle exploration emitted an unexpected search pulse")
} else {
    require(false, "idle exploration did not begin after uncalibrated visual input")
}
if case .velocity = idleExploration.beginIfEligible(at: start + 2_000_000_000) {
    // Continued visual absence keeps the search loop eligible.
} else {
    require(false, "idle exploration did not continue during visual absence")
}
let noTargetDirective = embodiedPolicy.directive(for: PredictiveWorldModel().snapshot(at: start), owner: .external)
require(noTargetDirective.stopRequested && noTargetDirective.externalPanSpeed == 0, "external owner did not request stop after target loss")

var arbiter = CameraOwnerArbiter()
require(arbiter.request(.nativeAI), "manual owner could not enter native AI")
require(!arbiter.request(.external), "external control overlapped native AI")
arbiter.recordFault()
require(arbiter.owner == .fault, "failed acknowledgement did not enter fault")
require(arbiter.confirmManualStop() && arbiter.owner == .manual, "fault could not recover only through confirmed manual stop")
require(arbiter.request(.external), "manual owner could not enter external control")
require(arbiter.confirmManualStop() && arbiter.owner == .manual, "external control could not return to manual")

func l05Context(
    at monotonicNS: UInt64,
    label: String? = nil,
    surprise: Double = 0,
    informationGain: Double = 0
) -> L05FrameContext {
    L05FrameContext(
        captureNS: monotonicNS,
        trigger: "test",
        surprise: surprise,
        informationGain: informationGain,
        presenceProbability: label == nil ? 0 : 0.8,
        voiceProbability: 0,
        targetKind: label == nil ? nil : .human,
        targetLabel: label,
        targetProbability: label == nil ? 0 : 0.8,
        targetStatus: label == nil ? .none : .tracked
    )
}
let l05Start: UInt64 = 30_000_000_000
var l05Admission = L05SemanticAdmissionGate()
require(l05Admission.admit(l05Context(at: l05Start)), "L0.5 rejected its first keyframe")
require(!l05Admission.admit(l05Context(at: l05Start + 999_000_000, label: "face")), "L0.5 exceeded its one-hertz event bound")
require(l05Admission.admit(l05Context(at: l05Start + 1_000_000_000, label: "face")), "L0.5 did not admit a changed target at one second")
require(!l05Admission.admit(l05Context(at: l05Start + 5_999_000_000, label: "face")), "L0.5 refreshed an unchanged scene before five seconds")
require(l05Admission.admit(l05Context(at: l05Start + 6_000_000_000, label: "face")), "L0.5 did not refresh an unchanged scene at five seconds")
require(l05Admission.admit(l05Context(at: l05Start + 7_000_000_000, label: "face", surprise: 0.7)), "L0.5 did not admit a salient event at one second")
print("soma-core-check: PASS")
