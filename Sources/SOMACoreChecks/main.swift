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
let conversationAnchorModel = PredictiveWorldModel()
let conversationAnchor = conversationAnchorModel.ingestVisual(
    VisualObservation(
        rect: rect(0.4),
        confidence: 0.90,
        source: .neuralFaceDetector,
        kind: .human,
        label: "face",
        isActionEligible: true
    ),
    at: start
)
require(
    LiveConversationVisualAdmission.permitsNewSession(for: conversationAnchor),
    "verified human fixation did not admit a new live conversation"
)
let ambientObjectModel = PredictiveWorldModel()
let ambientObject = ambientObjectModel.ingestVisual(
    VisualObservation(
        rect: rect(0.4),
        confidence: 0.90,
        source: .neuralDetector,
        kind: .object,
        label: "object",
        isActionEligible: false
    ),
    at: start
)
require(
    !LiveConversationVisualAdmission.permitsNewSession(for: ambientObject),
    "ambient object admitted a new live conversation"
)
var contactGate = ConversationContactGate()
require(
    contactGate.observeVoiceActivity(active: true, at: start, directContact: false) == nil,
    "ambient speech authorized a new spoken turn"
)
require(
    contactGate.observeVoiceActivity(
        active: true,
        at: start + 100_000_000,
        directContact: true
    ) == nil,
    "later eye contact upgraded an already-rejected ambient sound"
)
_ = contactGate.observeVoiceActivity(
    active: false,
    at: start + 200_000_000,
    directContact: true
)
require(
    contactGate.observeVoiceActivity(
        active: true,
        at: start + 300_000_000,
        directContact: true
    ) == .voiceActivity,
    "direct contact did not authorize the first spoken turn"
)
_ = contactGate.observeVoiceActivity(
    active: false,
    at: start + 400_000_000,
    directContact: true
)
require(
    contactGate.observeVoiceActivity(
        active: true,
        at: start + 1_100_000_000,
        directContact: false
    ) == nil,
    "speech without current direct contact authorized a new spoken turn"
)
var l0FaceFixationAdmission = L0FaceFixationAdmission(freshnessMilliseconds: 500)
l0FaceFixationAdmission.observeVerifiedFixation(
    sceneID: "face-a",
    directContact: true,
    at: start
)
require(
    l0FaceFixationAdmission.permitsNewSession(at: start + 100_000_000),
    "current verified L0 face fixation did not admit direct speech"
)
l0FaceFixationAdmission.clear()
require(
    !l0FaceFixationAdmission.permitsNewSession(at: start + 100_000_000),
    "cleared L0 fixation still admitted historical gaze"
)
contactGate.markConversationOpened(at: start + 2_000_000_000)
_ = contactGate.observeVoiceActivity(
    active: false,
    at: start + 2_100_000_000,
    directContact: false
)
require(
    contactGate.observeVoiceActivity(
        active: true,
        at: start + 61_999_000_000,
        directContact: false
    ) == .activeConversation,
    "opened conversation did not retain its active lease"
)
_ = contactGate.observeVoiceActivity(
    active: false,
    at: start + 61_999_500_000,
    directContact: false
)
require(
    contactGate.observeVoiceActivity(
        active: true,
        at: start + 62_000_000_000,
        directContact: true
    ) == .voiceActivity,
    "direct contact did not remain admissible after the conversation lease closed"
)
var liveSessionInactivity = LiveVoiceSessionInactivityGate()
let firstLiveDeadline = liveSessionInactivity.activate(at: start)
require(
    !liveSessionInactivity.shouldClose(at: firstLiveDeadline - 1),
    "Live voice session closed before one minute of user silence"
)
require(
    liveSessionInactivity.shouldClose(at: firstLiveDeadline),
    "Live voice session did not close after one minute of user silence"
)
let renewedLiveDeadline = liveSessionInactivity.recordUserActivity(at: firstLiveDeadline - 1)
require(
    renewedLiveDeadline == firstLiveDeadline + 59_999_999_999,
    "user activity did not renew the Live voice silence deadline"
)
var indicatorInputs = SubconsciousIndicatorInputs(
    visualState: .eyeContact,
    interactionState: .idle
)
require(indicatorInputs.resolvedState == .contactReady, "contact-ready LED priority is wrong")
indicatorInputs.interactionState = .conversation
require(indicatorInputs.resolvedState == .conversation, "conversation LED priority is wrong")
indicatorInputs.interactionState = .preparingReply
require(indicatorInputs.resolvedState == .working, "working LED priority is wrong")
let tiny3Contract = OBSBOTDeviceContract.parse(
    "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_3_lite product_type=19 "
        + "native_bridge=true motor_calibrated=false bounded_calibration_pulses=true "
        + "native_human_tracking=true indicator_palette=true indicator_default_green=false indicator_direct_rgb=false "
        + "indicator_direct_rgb_mask=0 indicator_basic=true indicator_pulse_transport=2 selectable_audio_modes=true "
        + "supported_audio_mode_mask=55 sound_localization=true requires_measured_attitude_frame=true "
        + "native_tracking_transport=2 indicator_yellow_state_id=16 indicator_green_state_id=54 "
        + "indicator_blue_state_id=57 maximum_pan_degrees_per_second=90 "
        + "maximum_pitch_degrees_per_second=45 nominal_wide_horizontal_fov_degrees=72"
)!
let contactReadyRendering = SOMALEDSettings().deviceRendering(for: .contactReady, on: tiny3Contract)
let humanDetectedRendering = SOMALEDSettings().deviceRendering(for: .humanDetected, on: tiny3Contract)
let tiny2OpenContract = OBSBOTDeviceContract(
    profileID: OBSBOTDeviceProfile.tiny2Lite.rawValue,
    productType: 3,
    firmware: "open_uvc_xu",
    supportsNativeBridge: true,
    supportsNativeHumanTracking: true,
    capabilities: OBSBOTDeviceCapabilities(
        supportsCalibratedMotorControl: true,
        supportsBoundedCalibrationPulses: false,
        supportsFirmwareIndicatorPalette: true,
        supportsDirectIndicatorRGB: false,
        supportsIndicatorEnableAndBrightness: true,
        supportsSelectableAudioModes: false,
        supportsDeviceSoundLocalization: false,
        requiresMeasuredAttitudeFrame: false,
        maximumPanDegreesPerSecond: 180,
        maximumPitchDegreesPerSecond: 90,
        nominalWideHorizontalFieldOfViewDegrees: 67.2
    ),
    indicatorStateIDs: [.yellow: 16, .green: 54, .blue: 57],
    indicatorPulseTransport: .brightnessDimming,
    nativeTrackingTransport: .legacyHumanMode
)
require(
    contactReadyRendering == SOMALEDDeviceRendering(stateID: 57, pattern: .blink)
        && humanDetectedRendering == SOMALEDDeviceRendering(stateID: 57, pattern: .steady)
        && SOMALEDSettings().deviceRendering(for: .conversation, on: tiny3Contract)
            == SOMALEDDeviceRendering(stateID: 16, pattern: .steady),
    "Tiny 3 LED contract did not expose its physically validated presentations"
)
require(
    SOMALEDSettings().deviceRendering(
        for: .conversation,
        on: tiny3Contract,
        eyeContactActive: true
    ) == SOMALEDDeviceRendering(stateID: 16, pattern: .blink)
        && SOMALEDSettings().deviceRendering(
            for: .conversation,
            on: tiny3Contract,
            eyeContactActive: false
        ) == SOMALEDDeviceRendering(stateID: 16, pattern: .steady),
    "conversation eye contact did not modulate cadence without changing the session colour"
)
require(
    SOMALEDSettings().deviceRendering(
        for: .conversation,
        on: tiny2OpenContract,
        eyeContactActive: true
    ) == SOMALEDDeviceRendering(stateID: 16, pattern: .blink),
    "Tiny 2 open bridge did not preserve yellow while exposing conversation eye contact"
)
require(
    SubconsciousIndicatorState.contactReady.humanMeaning == "ready_speak_now"
        && SubconsciousIndicatorState.working.humanMeaning == "conversation_active",
    "LED state does not expose a human-readable interaction affordance"
)
var indicatorLease = EyeContactIndicatorLease(holdMilliseconds: 3_000)
indicatorLease.observe(at: start)
require(
    indicatorLease.isActive(at: start + 2_999_000_000),
    "indicator eye-contact lease ended during the dropout tolerance"
)
require(
    indicatorLease.isActive(at: start + 3_000_000_000),
    "indicator eye-contact lease excluded its configured boundary"
)
require(
    !indicatorLease.isActive(at: start + 3_001_000_000),
    "indicator eye-contact lease outlived its configured hold"
)
indicatorLease.clear()
require(
    !indicatorLease.isActive(at: start + 3_001_000_000),
    "indicator eye-contact lease did not clear"
)
indicatorLease.observe(sceneID: "face-a", at: start)
require(
    indicatorLease.maintain(sceneID: "face-a", at: start + 100_000_000)
        && indicatorLease.isActive(at: start + 2_999_000_000),
    "current locked face did not sustain the contact-ready indicator"
)
require(
    !indicatorLease.maintain(sceneID: "face-a", at: start + 3_001_000_000)
        && !indicatorLease.maintain(sceneID: "face-b", at: start + 3_001_000_000),
    "contact-ready indicator outlived its bounded face lease"
)
var indicatorPresence = SubconsciousIndicatorInputs()
indicatorPresence.observeHumanVisualPresence()
require(
    indicatorPresence.visualState == .humanDetected,
    "fresh human presence did not immediately become a human-detected indicator"
)
indicatorPresence.visualState = .eyeContact
indicatorPresence.observeHumanVisualPresence()
require(
    indicatorPresence.visualState == .eyeContact,
    "ordinary human presence downgraded an active eye-contact indicator"
)
var contactEpisode = L1ConversationContactEpisode()
require(
    !contactEpisode.observeFinalizedTurn(role: .assistant)
        && contactEpisode.closureKind(interrupted: false) == .conversationEndedWithoutParticipantTurn,
    "assistant output was mistaken for a participant response"
)
require(
    contactEpisode.observeFinalizedTurn(role: .user)
        && !contactEpisode.observeFinalizedTurn(role: .user)
        && contactEpisode.closureKind(interrupted: false) == .conversationEnded
        && contactEpisode.closureKind(interrupted: true) == .conversationInterrupted,
    "voice contact episode did not preserve response and closure facts"
)
var liveVoiceGate = LiveVoiceLaunchGate()
require(liveVoiceGate.beginLaunch(at: start), "app-server Live launch did not arm")
require(!liveVoiceGate.beginLaunch(at: start + 1), "app-server Live launch was not debounced")
liveVoiceGate.fail(at: start, retryMilliseconds: 5_000)
require(
    !liveVoiceGate.beginLaunch(at: start + 4_999_999_999),
    "app-server Live retry cooldown ended early"
)
require(
    liveVoiceGate.beginLaunch(at: start + 5_000_000_000),
    "Live voice retry did not rearm at its deadline"
)
liveVoiceGate.observeActive()
require(!liveVoiceGate.beginLaunch(at: start + 6_000_000_000), "active Voice relaunched")
liveVoiceGate.observeEnded()
require(liveVoiceGate.beginLaunch(at: start + 6_000_000_000), "ended Voice did not rearm")
let firstPresenceIdentity = IdentityPresenceIdentity(
    entityID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    kind: .enrolled
)
let secondPresenceIdentity = IdentityPresenceIdentity(
    entityID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    kind: .pseudonymous
)
var identityPresence = IdentityPresenceTracker()
require(
    identityPresence.observe(firstPresenceIdentity, at: start) == [.arrived(firstPresenceIdentity)],
    "recognized person did not create one arrival"
)
require(
    identityPresence.observe(secondPresenceIdentity, at: start + 200_000_000)
        == [.replacementCandidate(previous: firstPresenceIdentity, candidate: secondPresenceIdentity, confirmations: 1)],
    "one mismatched identity replaced the active participant"
)
require(
    identityPresence.observe(firstPresenceIdentity, at: start + 400_000_000).isEmpty
        && identityPresence.currentIdentity == firstPresenceIdentity,
    "returning identity did not clear a replacement candidate"
)
require(
    identityPresence.observe(secondPresenceIdentity, at: start + 600_000_000)
        == [.replacementCandidate(previous: firstPresenceIdentity, candidate: secondPresenceIdentity, confirmations: 1)]
        && identityPresence.observe(secondPresenceIdentity, at: start + 800_000_000)
        == [.replaced(previous: firstPresenceIdentity, current: secondPresenceIdentity)],
    "repeated alternate identity did not create a confirmed replacement"
)
require(
    identityPresence.advance(at: start + 3_299_999_999).isEmpty
        && identityPresence.advance(at: start + 3_300_000_000) == [.departed(secondPresenceIdentity)],
    "identity presence departed before or after its visual-absence boundary"
)
let wideHorizontalFOV = CameraFieldOfView.horizontalDegrees(
    diagonalDegrees: 86,
    aspectRatio: 16.0 / 9.0
)
let wideVerticalFOV = CameraFieldOfView.verticalDegrees(
    diagonalDegrees: 86,
    aspectRatio: 16.0 / 9.0
)
require(
    abs((wideHorizontalFOV ?? 0) - 78.205) < 0.001
        && abs((wideVerticalFOV ?? 0) - 49.137) < 0.001,
    "generic diagonal FOV conversion is inconsistent"
)
require(
    abs((OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 86) ?? 0) - 67.2) < 0.001
        && abs((OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 78) ?? 0) - 59.966) < 0.001
        && abs((OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 65) ?? 0) - 48.827) < 0.001
        && OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 70) == nil,
    "Tiny 2 Lite FOV mode was treated as a physical diagonal angle"
)
let validatedCameraGeometry = CameraGeometryCalibration(
    deviceProfile: "obsbot_tiny_2_lite",
    fovMode: 86,
    imageWidth: 1920,
    imageHeight: 1080,
    projection: CameraProjectionModel(
        focalXNormalized: 0.824,
        focalYNormalized: 1.408,
        principalXNormalized: 0.490,
        principalYNormalized: 0.537
    ),
    capturedFrames: 29,
    fittedPairs: 15,
    fittedMatches: 837,
    validationPairs: 5,
    validationMatches: 270,
    initialRMSEPixels: 23.44,
    calibratedRMSEPixels: 5.96,
    calibratedP90Pixels: 9.37,
    generatedAt: "2026-08-15T00:00:00Z"
)
require(validatedCameraGeometry.isValid, "independently validated camera geometry was rejected")
var calibratedSceneField = SceneField()
let calibratedUpperCandidate = calibratedSceneField.ingest(
    [VisualObservation(
        rect: NormalizedRect(x: 0.45, y: 0.15, width: 0.10, height: 0.10),
        confidence: 0.9,
        source: .neuralDetector,
        kind: .object,
        label: "test"
    )],
    at: start,
    cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    horizontalFieldOfViewDegrees: 67.2,
    cameraSettled: true,
    poseProjection: .identity,
    cameraProjectionModel: validatedCameraGeometry.projection
).first
require(
    (calibratedUpperCandidate?.bearing?.elevationDegrees ?? -90) > 0,
    "top-left detector coordinates were not converted into calibrated camera pixels"
)
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
    ) == (3 / 0.45 + 1.5),
    "distant exploration waypoint ignored realized-speed margin and could stop halfway"
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
let gimbalEnvelope = GimbalKinematicEnvelope.obsbotTiny2Lite
require(
    gimbalEnvelope.containsTrackingCenter(
        GimbalRelativeBearing(azimuthDegrees: 110.8, elevationDegrees: 24.8)
    )
        && !gimbalEnvelope.containsTrackingCenter(
            GimbalRelativeBearing(azimuthDegrees: 126.1, elevationDegrees: 0)
        )
        && !gimbalEnvelope.containsTrackingCenter(
            GimbalRelativeBearing(azimuthDegrees: 0, elevationDegrees: -34.1)
        ),
    "tracking-envelope recovery did not preserve normal autonomous-boundary overshoot"
)
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
let panoramaCentredGuide = GimbalVisibilityRoutePlanner.guide(
    to: GimbalRelativeBearing(azimuthDegrees: 72, elevationDegrees: 0),
    from: routeOrigin,
    observationPreference: .centered
)
require(
    abs((panoramaCentredGuide?.azimuthDegrees ?? 0) - 72) < 0.000_001,
    "panorama exploration left a reachable quality target at the FOV edge"
)
let edgeVisibleRoute = GimbalVisibilityRoutePlanner.plan(
    to: GimbalRelativeBearing(azimuthDegrees: 140, elevationDegrees: 38),
    from: routeOrigin
)
require(
    edgeVisibleRoute != nil
        && abs(edgeVisibleRoute!.observationPose.azimuthDegrees)
            <= GimbalKinematicEnvelope.obsbotTiny2Lite.maximumAutonomousPanDegrees
        && abs(edgeVisibleRoute!.observationPose.elevationDegrees)
            <= GimbalKinematicEnvelope.obsbotTiny2Lite.maximumAutonomousPitchDegrees,
    "edge-visible target produced an out-of-envelope camera centre"
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
require(stationaryFaceCandidate?.faceInteractionLivenessEligible == false, "stationary face authorized social interaction")
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
require(jitteredFaceCandidate?.faceInteractionLivenessEligible == false, "one detector jitter established interaction liveness")
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
require(activeFaceCandidate?.faceInteractionLivenessEligible == true, "consistent real face motion did not establish interaction liveness")
let expiredFaceCandidate = faceActivityField.ingest(
        [activeFace], at: start + 1_700_000_001,
        cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 1_700_000_001),
        cameraSettled: true
    ).first
require(expiredFaceCandidate?.isActionEligible == true, "current confirmed face evidence was discarded")
require(expiredFaceCandidate?.faceActivityEligible == false, "inactive face retained acquisition authority")
require(expiredFaceCandidate?.faceInteractionLivenessEligible == false, "discontinuous face retained interaction liveness")
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
    !FaceLockLease.permitsProvisionalExplorationInterception(observationCount: 3, confidence: 0),
    "invalid exploration face evidence opened provisional motor authority"
)
require(
    FaceLockLease.permitsProvisionalExplorationInterception(observationCount: 2, confidence: 0.55),
    "repeated detector evidence could not preempt coverage"
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
    horizontalFieldOfViewDegrees: 70,
    poseProjection: .obsbotTiny2Lite
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
    horizontalFieldOfViewDegrees: 70,
    poseProjection: .obsbotTiny2Lite
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
], at: start + 61_100_000_000, cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 50, monotonicNS: start + 61_100_000_000), horizontalFieldOfViewDegrees: 70, poseProjection: .obsbotTiny2Lite)
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
let panoramaPose = CaptureAlignedPoseInterpolator.estimate(
    samples: [
        GimbalPose(pitchDegrees: -8, panDegrees: 10, monotonicNS: start),
        GimbalPose(pitchDegrees: 4, panDegrees: 34, monotonicNS: start + 40_000_000),
    ],
    at: start + 10_000_000
)
require(panoramaPose?.mode == .bracketed, "panorama did not bracket its exposure attitude")
require(abs((panoramaPose?.pose.panDegrees ?? 0) - 16) < 0.000_001, "panorama pan interpolation drifted")
require(abs((panoramaPose?.pose.pitchDegrees ?? 0) + 5) < 0.000_001, "panorama pitch interpolation drifted")
require(
    abs((panoramaPose?.angularVelocityDegreesPerSecond ?? 0) - hypot(24, 12) / 0.04) < 0.000_001,
    "panorama motion quality lost the bracketed angular velocity"
)
let exactMovingPanoramaPose = CaptureAlignedPoseInterpolator.estimate(
    samples: [
        GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
        GimbalPose(pitchDegrees: 0, panDegrees: 10, monotonicNS: start + 100_000_000),
        GimbalPose(pitchDegrees: 0, panDegrees: 20, monotonicNS: start + 200_000_000),
    ],
    at: start + 100_000_000
)
require(
    exactMovingPanoramaPose?.mode == .exact
        && abs((exactMovingPanoramaPose?.angularVelocityDegreesPerSecond ?? 0) - 100) < 0.000_001,
    "exact panorama pose hid local camera motion"
)
require(
    CaptureAlignedPoseInterpolator.estimate(
        samples: [freshSpatialPose],
        at: start + 10_000_000
    ) == nil,
    "panorama guessed a pose without a future measured attitude"
)
let panoramaCenter = SphericalPanoramaProjection.sourceCoordinate(
    for: GimbalRelativeBearing(azimuthDegrees: 0, elevationDegrees: 0),
    cameraPose: freshSpatialPose,
    horizontalFieldOfViewDegrees: 86
)
require(abs((panoramaCenter?.normalizedX ?? 0) - 0.5) < 0.000_001, "panorama horizontal centre projection drifted")
require(abs((panoramaCenter?.normalizedY ?? 0) - 0.5) < 0.000_001, "panorama vertical centre projection drifted")
let obsbotCanonicalCenter = SphericalPanoramaProjection.sourceCoordinate(
    for: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: -5),
    cameraPose: GimbalPose(pitchDegrees: 5, panDegrees: 20, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86,
    poseProjection: .obsbotTiny2Lite
)
let obsbotCanonicalTop = SphericalPanoramaProjection.sourceCoordinate(
    for: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: 5),
    cameraPose: GimbalPose(pitchDegrees: 5, panDegrees: 20, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86,
    poseProjection: .obsbotTiny2Lite
)
require(
    abs((obsbotCanonicalCenter?.normalizedX ?? 0) - 0.5) < 0.000_001
        && abs((obsbotCanonicalCenter?.normalizedY ?? 0) - 0.5) < 0.000_001
        && (obsbotCanonicalTop?.normalizedY ?? 1) < 0.5,
    "OBSBOT stabilized attitude was not converted once into the upright canonical sphere"
)
let panoramaUpperLeft = SphericalPanoramaProjection.outputBearing(
    column: 0,
    row: 0,
    width: 100,
    height: 50,
    minimumElevationDegrees: -45,
    maximumElevationDegrees: 45
)
let panoramaLowerRight = SphericalPanoramaProjection.outputBearing(
    column: 99,
    row: 49,
    width: 100,
    height: 50,
    minimumElevationDegrees: -45,
    maximumElevationDegrees: 45
)
require(
    panoramaUpperLeft.azimuthDegrees < panoramaLowerRight.azimuthDegrees
        && panoramaUpperLeft.elevationDegrees > panoramaLowerRight.elevationDegrees,
    "panorama raster did not preserve the standard world spherical orientation"
)
let coupledSphericalCoordinate = SphericalPanoramaProjection.sourceCoordinate(
    for: GimbalRelativeBearing(azimuthDegrees: 30, elevationDegrees: 30),
    cameraPose: GimbalPose(pitchDegrees: 30, panDegrees: 0, monotonicNS: start),
    horizontalFieldOfViewDegrees: 86,
    poseProjection: .identity
)
require(
    coupledSphericalCoordinate != nil
        && abs(coupledSphericalCoordinate!.normalizedY - 0.5) > 0.01,
    "panorama projection treated yaw and pitch as independent planar offsets"
)
let fastPanoramaQuality = PanoramaObservationQuality.motionQuality(
    angularVelocityDegreesPerSecond: 60
)
require(
    PanoramaObservationQuality.admitsProjection(angularVelocityDegreesPerSecond: 2.0)
        && !PanoramaObservationQuality.admitsProjection(angularVelocityDegreesPerSecond: 2.001)
        && PanoramaObservationQuality.admitsCalibration(angularVelocityDegreesPerSecond: 0.75)
        && !PanoramaObservationQuality.admitsCalibration(angularVelocityDegreesPerSecond: 0.751)
        && PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: 20,
            horizontalFieldOfViewDegrees: 62
        ) != nil
        && PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: 40.001,
            horizontalFieldOfViewDegrees: 62
        ) == nil
        && fastPanoramaQuality < 0.15
        && !PanoramaObservationQuality.shouldReplace(
            existingQuality: 0.9,
            incomingQuality: fastPanoramaQuality
        )
        && PanoramaObservationQuality.shouldReplace(
            existingQuality: 0,
            incomingQuality: fastPanoramaQuality
        ),
    "panorama quality selection allowed a fast pass to smear a stable tile"
)
require(
    !PanoramaObservationQuality.shouldReplace(
        existingQuality: 0.9,
        incomingQuality: 0.9
    )
        && PanoramaObservationQuality.shouldReplace(
            existingQuality: 0.9,
            incomingQuality: 0.94
        ),
    "panorama overlap lacked best-observation replacement hysteresis"
)
let registrationWidth = 1_280
let registrationTranslation = tan(10 * .pi / 180)
    / (2 * tan(43 * .pi / 180)) * Double(registrationWidth)
let refinedPanoramaPose = PanoramaPoseRefinement.refine(
    previousPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 9, monotonicNS: start + 1),
    alignmentTranslationX: registrationTranslation,
    alignmentTranslationY: 0,
    imageWidth: registrationWidth,
    imageHeight: 720,
    horizontalFieldOfViewDegrees: 86,
    confidence: 1,
    poseProjection: .identity
)
require(
    refinedPanoramaPose.accepted
        && refinedPanoramaPose.correctedPose.panDegrees > 9
        && refinedPanoramaPose.correctedPose.panDegrees <= 10
        && abs(refinedPanoramaPose.panCorrectionDegrees) <= 86 * 0.04,
    "local image registration did not refine the capture-aligned panorama pose"
)
let rejectedPanoramaPose = PanoramaPoseRefinement.refine(
    previousPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 9, monotonicNS: start + 1),
    alignmentTranslationX: 1_200,
    alignmentTranslationY: 0,
    imageWidth: registrationWidth,
    imageHeight: 720,
    horizontalFieldOfViewDegrees: 86,
    confidence: 1,
    poseProjection: .identity
)
require(
    !rejectedPanoramaPose.accepted
        && abs(rejectedPanoramaPose.correctedPose.panDegrees - 9) < 0.000_001,
    "out-of-model image motion overrode the measured gimbal pose"
)
let lowConfidencePanoramaPose = PanoramaPoseRefinement.refine(
    previousPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
    currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 9, monotonicNS: start + 1),
    alignmentTranslationX: registrationTranslation,
    alignmentTranslationY: 0,
    imageWidth: registrationWidth,
    imageHeight: 720,
    horizontalFieldOfViewDegrees: 86,
    confidence: 0.4,
    poseProjection: .identity
)
require(
    !lowConfidencePanoramaPose.accepted
        && abs(lowConfidencePanoramaPose.correctedPose.panDegrees - 9) < 0.000_001,
    "low-confidence image registration overrode the measured gimbal pose"
)
let placeValues = Array(1...24).map(Float.init)
let placeEmbedding = PanoramaPlaceEmbedding(
    encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
    revision: 2,
    values: placeValues
)
let scaledPlaceEmbedding = PanoramaPlaceEmbedding(
    encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
    revision: 2,
    values: placeValues.map { $0 * 3 }
)
require(
    placeEmbedding != nil
        && scaledPlaceEmbedding != nil
        && abs((placeEmbedding!.similarity(to: scaledPlaceEmbedding!) ?? 0) - 1) < 0.000_001,
    "compatible learned place embedding lost scale-invariant similarity"
)
var placeCoverageField = SpatialCoverageField()
let firstPlace = placeCoverageField.observePlace(
    embedding: placeEmbedding!,
    pose: GimbalPose(pitchDegrees: 1, panDegrees: 3, monotonicNS: start),
    observationQuality: 1,
    at: start
)
let revisitedPlace = placeCoverageField.observePlace(
    embedding: scaledPlaceEmbedding!,
    pose: GimbalPose(pitchDegrees: 1, panDegrees: 3, monotonicNS: start + 1_000_000_000),
    observationQuality: 1,
    at: start + 1_000_000_000
)
let placeCells = placeCoverageField.snapshot(at: start + 1_000_000_000)
let recognizedPlaceCells = placeCells.filter { $0.placeObservationCount > 0 }
let unknownPlaceCell = placeCells.first { $0.placeObservationCount == 0 }
require(
    firstPlace?.isRevisit == false
        && revisitedPlace?.isRevisit == true
        && firstPlace?.bearing == revisitedPlace?.bearing
        && revisitedPlace?.observationCount == 2
        && (revisitedPlace?.familiarity ?? 0) > 0.999
        && recognizedPlaceCells.count == 1
        && recognizedPlaceCells.first?.placeObservationCount == 2,
    "spherical place revisit created a duplicate or lost familiarity"
)
require(
    (unknownPlaceCell?.expectedInformationGain ?? 0)
        > (recognizedPlaceCells.first?.expectedInformationGain ?? 1),
    "epistemic exploration did not prefer an unresolved spherical place"
)
let placeMemorySnapshot = placeCoverageField.placeMemorySnapshot(
    generatedAtUnixMilliseconds: 123
)
var restoredPlaceCoverageField = SpatialCoverageField()
require(
    restoredPlaceCoverageField.restorePlaceMemory(
        placeMemorySnapshot,
        expectedEncoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
        expectedRevision: 2
    ) == 1
        && restoredPlaceCoverageField.snapshot(at: start + 2_000_000_000)
            .filter { $0.placeObservationCount > 0 }
            .first?.placeObservationCount == 2,
    "compatible spherical place memory did not survive a session restore"
)
let incompatiblePlaceEmbedding = PanoramaPlaceEmbedding(
    encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
    revision: 3,
    values: placeValues
)!
let incompatiblePlace = placeCoverageField.observePlace(
    embedding: incompatiblePlaceEmbedding,
    pose: GimbalPose(pitchDegrees: 1, panDegrees: 3, monotonicNS: start + 2_000_000_000),
    observationQuality: 1,
    at: start + 2_000_000_000
)
require(
    incompatiblePlace?.isRevisit == false && incompatiblePlace?.observationCount == 1,
    "an incompatible place encoder revision was merged as a revisit"
)
var panoramaAdmission = PanoramaBackgroundAdmission(humanHoldNS: 750_000_000)
require(
    !panoramaAdmission.admits(hasObservedHuman: true, at: start)
        && !panoramaAdmission.admits(hasObservedHuman: false, at: start + 749_999_999)
        && panoramaAdmission.admits(hasObservedHuman: false, at: start + 750_000_000),
    "panorama background admission leaked a human through a detector gap"
)
var coverageField = SpatialCoverageField()
coverageField.observe(pose: freshSpatialPose, horizontalFieldOfViewDegrees: 86, at: start)
let unexploredDirection = coverageField.nextDirection(from: freshSpatialPose, at: start + 100_000_000)
require(unexploredDirection != nil, "coverage field did not select an unexplored direction")
require(
    abs(unexploredDirection!.bearing.azimuthDegrees) > 43,
    "coverage field selected a direction already inside the current view"
)
var panoramaCoverageField = SpatialCoverageField()
for pitch in [-24.0, 24.0] {
    for pan in [-110.0, 0.0, 110.0] {
        panoramaCoverageField.observe(
            pose: GimbalPose(pitchDegrees: pitch, panDegrees: pan, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86,
            at: start
        )
    }
}
panoramaCoverageField.observePanorama(
    pose: freshSpatialPose,
    horizontalFieldOfViewDegrees: 86,
    frameQuality: 1,
    dynamicVisionRects: [],
    poseProjection: .identity,
    at: start
)
let panoramaDeficitDirection = panoramaCoverageField.nextDirection(
    from: freshSpatialPose,
    at: start + 1_000_000
)
require(
    panoramaDeficitDirection != nil && panoramaDeficitDirection!.panoramaQuality < 0.1,
    "coverage exploration ignored a poor spherical panorama tile"
)
var calibratedCoverageField = SpatialCoverageField()
calibratedCoverageField.observe(
    pose: freshSpatialPose,
    horizontalFieldOfViewDegrees: 86,
    poseProjection: .obsbotTiny2Lite,
    cameraProjectionModel: CameraProjectionModel(
        focalXNormalized: 0.824,
        focalYNormalized: 1.408,
        principalXNormalized: 0.60,
        principalYNormalized: 0.50
    ),
    at: start
)
let calibratedCoverageCells = calibratedCoverageField.snapshot(at: start)
require(
    calibratedCoverageCells.first {
        $0.bearing.azimuthDegrees == 36 && $0.bearing.elevationDegrees == 0
    }?.observationCount == 1
        && calibratedCoverageCells.first {
            $0.bearing.azimuthDegrees == -36 && $0.bearing.elevationDegrees == 0
        }?.observationCount == 0,
    "coverage atlas ignored calibrated principal point or device motor-axis signs"
)
require(abs(unexploredDirection!.bearing.elevationDegrees) <= 39, "coverage atlas exceeded its reachable vertical field")
let sampledCoverageDirection = coverageField.sampleNextDirection(
    from: freshSpatialPose,
    at: start + 100_000_000,
    temperature: 1.4,
    uniform: 0
)
require(sampledCoverageDirection != nil, "coverage posterior sampling did not draw a direction")
require(abs(sampledCoverageDirection!.bearing.elevationDegrees) == 39, "coverage posterior omitted its edge-visible vertical layers")
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
    require(abs(farPan) <= 36, "face servo exceeded its live device-speed cap")
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
    require(initialPan <= 36, "face servo started above its live device-speed cap")
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
    require(abs(handoffPan) <= 60, "nearby face scene-id churn bypassed the live device-speed cap")
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

func l1AuxiliaryContext(
    at monotonicNS: UInt64,
    label: String? = nil,
    surprise: Double = 0,
    informationGain: Double = 0
) -> L1AuxiliaryFrameContext {
    L1AuxiliaryFrameContext(
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
let l1AuxiliaryStart: UInt64 = 30_000_000_000
var l1AuxiliaryAdmission = L1AuxiliarySemanticAdmissionGate()
require(l1AuxiliaryAdmission.admit(l1AuxiliaryContext(at: l1AuxiliaryStart)), "L1 auxiliary rejected its first keyframe")
require(!l1AuxiliaryAdmission.admit(l1AuxiliaryContext(at: l1AuxiliaryStart + 999_000_000, label: "face")), "L1 auxiliary exceeded its one-hertz event bound")
require(l1AuxiliaryAdmission.admit(l1AuxiliaryContext(at: l1AuxiliaryStart + 1_000_000_000, label: "face")), "L1 auxiliary did not admit a changed target at one second")
require(!l1AuxiliaryAdmission.admit(l1AuxiliaryContext(at: l1AuxiliaryStart + 5_999_000_000, label: "face")), "L1 auxiliary refreshed an unchanged scene before five seconds")
require(l1AuxiliaryAdmission.admit(l1AuxiliaryContext(at: l1AuxiliaryStart + 6_000_000_000, label: "face")), "L1 auxiliary did not refresh an unchanged scene at five seconds")
require(l1AuxiliaryAdmission.admit(l1AuxiliaryContext(at: l1AuxiliaryStart + 7_000_000_000, label: "face", surprise: 0.7)), "L1 auxiliary did not admit a salient event at one second")
func l1AuxiliaryCue(
    at monotonicNS: UInt64,
    situation: L1AuxiliarySituation,
    reason: L1AuxiliaryWakeReason,
    score: Double = 0.9,
    confidence: Double = 0.9
) -> L1AuxiliarySemanticCue {
    L1AuxiliarySemanticCue(
        requestID: monotonicNS,
        captureNS: monotonicNS,
        completedNS: monotonicNS,
        source: "test",
        summary: "bounded visible evidence",
        novelty: 0.8,
        socialPresence: situation == .socialBid ? 0.9 : 0,
        attentionHint: situation == .socialBid ? .person : .none,
        situation: situation,
        wakeReason: reason,
        wakeScore: score,
        confidence: confidence,
        inferenceMS: 100
    )
}
var l1AuxiliaryInterruptGate = L1AuxiliarySemanticInterruptGate()
require(
    l1AuxiliaryInterruptGate.recommend(l1AuxiliaryCue(at: l1AuxiliaryStart, situation: .ambient, reason: .none)) == nil,
    "ambient L1 auxiliary evidence emitted a conscious wake proposal"
)
require(
    l1AuxiliaryInterruptGate.recommend(l1AuxiliaryCue(at: l1AuxiliaryStart, situation: .socialBid, reason: .presentedObject)) == nil,
    "inconsistent L1 auxiliary situation and wake reason emitted a proposal"
)
require(
    l1AuxiliaryInterruptGate.recommend(l1AuxiliaryCue(at: l1AuxiliaryStart, situation: .socialBid, reason: .directSocialBid)) != nil,
    "credible direct social bid did not emit an L1 auxiliary wake proposal"
)
require(
    l1AuxiliaryInterruptGate.recommend(l1AuxiliaryCue(at: l1AuxiliaryStart + 4_999_000_000, situation: .socialBid, reason: .directSocialBid)) != nil,
    "credible L1 auxiliary evidence was suppressed before workspace reduction"
)
require(
    l1AuxiliaryInterruptGate.recommend(l1AuxiliaryCue(at: l1AuxiliaryStart + 5_000_000_000, situation: .socialBid, reason: .directSocialBid)) != nil,
    "credible L1 auxiliary evidence did not remain available to workspace reduction"
)

func l1AuxiliaryTemporalCue(
    at monotonicNS: UInt64,
    socialPresence: Double = 0.95,
    eyeContact: Double = 0.95,
    engagement: Double = 0.90
) -> L1AuxiliarySemanticCue {
    L1AuxiliarySemanticCue(
        requestID: monotonicNS,
        captureNS: monotonicNS,
        completedNS: monotonicNS,
        source: "core-check",
        summary: "bounded temporal evidence",
        novelty: 0.1,
        socialPresence: socialPresence,
        attentionHint: socialPresence > 0 ? .person : .none,
        situation: .ambient,
        wakeReason: .none,
        wakeScore: 0.1,
        confidence: 0.90,
        eyeContact: eyeContact,
        engagement: engagement,
        inferenceMS: 100
    )
}
var l1AuxiliaryTemporalGate = L1AuxiliaryTemporalSituationGate()
let temporalStart = l1AuxiliaryStart + 20_000_000_000
require(
    l1AuxiliaryTemporalGate.recommend(l1AuxiliaryTemporalCue(at: temporalStart)) == nil,
    "one temporal cue emitted an L1 wake"
)
require(
    l1AuxiliaryTemporalGate.recommend(l1AuxiliaryTemporalCue(at: temporalStart + 5_000_000_000)) == nil,
    "short temporal evidence emitted an L1 wake"
)
let temporalInterrupt = l1AuxiliaryTemporalGate.recommend(
    l1AuxiliaryTemporalCue(at: temporalStart + 10_000_000_000)
)
require(
    temporalInterrupt?.reason == .temporalContext,
    "persistent temporal evidence did not emit the temporal-context wake"
)
require(
    l1AuxiliaryTemporalGate.recommend(l1AuxiliaryTemporalCue(at: temporalStart + 15_000_000_000)) == nil,
    "latched temporal context emitted a duplicate L1 wake"
)

let importanceModel = EventImportanceModel()
func importanceDecision(_ id: String, _ features: EventImportanceFeatures) -> EventImportanceDecision {
    importanceModel.evaluate(
        EventImportanceInput(
            eventID: id,
            monotonicNS: l1AuxiliaryStart,
            evidenceIDs: ["core-check:\(id)"],
            features: features
        )
    )
}
let nonHumanNovelty = importanceDecision(
    "nonhuman-novelty",
    EventImportanceFeatures(
        novelty: 1,
        predictionError: 0.9,
        informationGain: 0.9,
        persistence: 0.8
    )
)
require(nonHumanNovelty.recommendedRoute == .wakeL1, "non-human novelty did not route to L1")
require(nonHumanNovelty.distribution.requestHumanInteraction == 0, "non-human novelty could open human interaction")
require(abs(nonHumanNovelty.distribution.sum - 1) < 1e-12, "event route probabilities do not normalize")
let directContact = importanceDecision(
    "direct-contact",
    EventImportanceFeatures(
        explicitContact: 0.95,
        socialSalience: 0.9,
        interruptionCost: 1,
        recentWakePressure: 1,
        humanPresence: 0.95
    )
)
require(directContact.recommendedRoute == .requestHumanInteraction, "explicit human contact did not open interaction")
require(directContact.dispatch.openHumanInteraction, "explicit human contact did not dispatch interaction immediately")
require(directContact.dispatch.wakeL1Context, "explicit human contact did not build L1 context in parallel")
require(directContact.dispatch.bypassesL1Admission, "explicit human contact still waited for L1 admission")
require(directContact.policyReason == .explicitHumanContact, "direct contact lost its transition reason")
do {
    let interactionWake = try HumanInteractionWakeRequest(
        decision: directContact,
        audioPreRollMilliseconds: 900
    )
    require(interactionWake.bypassesL1Admission, "interaction wake no longer bypasses L1 admission")
    let codexTurn = try CodexInteractionTurn(
        interactionID: "core-check-interaction",
        turnID: "core-check-turn",
        transcript: "hello",
        speechStartedAtNS: l1AuxiliaryStart,
        transcriptFinalizedAtNS: l1AuxiliaryStart + 1,
        evidenceIDs: interactionWake.evidenceIDs,
        contextPacketReference: "context:core-check"
    )
    let encodedTurn = try JSONEncoder().encode(codexTurn)
    require(
        !String(decoding: encodedTurn, as: UTF8.self).lowercased().contains("audio"),
        "Codex interaction contract admitted raw audio"
    )
    let codexContext = try CodexInteractionContext(
        situationSummary: "A person is addressing the camera.",
        identityReference: "person:unknown",
        activeTaskSummaries: ["Respond to the current user turn."],
        memorySummaries: ["No identity claim is authorized."]
    )
    let codexRequest = try CodexAccountTurnRequest(turn: codexTurn, context: codexContext)
    let codexPrompt = CodexAccountPromptBuilder.prompt(for: codexRequest)
    require(codexPrompt.contains("hello"), "Codex account prompt dropped the transcript")
    let codexFixture = Data("""
    {"type":"thread.started","thread_id":"core-thread"}
    {"type":"item.completed","item":{"type":"agent_message","text":"hello back"}}
    {"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":0}}
    """.utf8)
    let codexResult = try CodexCLIJSONLParser.parse(codexFixture)
    require(codexResult.threadID == "core-thread", "Codex account parser lost the thread ID")
    require(codexResult.assistantText == "hello back", "Codex account parser lost the reply")

    var speechSegmenter = SpeechTurnSegmenter(configuration: .init(
        analysisLookbackMilliseconds: 260,
        maximumTurnMilliseconds: 1_000,
        rearmMilliseconds: 500
    ))
    require(
        speechSegmenter.observe(voiceActive: true, at: 1_000_000_000) == nil,
        "speech segmenter admitted voice without an authorized contact wake"
    )
    let speechStart = speechSegmenter.observe(
        voiceActive: true,
        at: 2_000_000_000,
        authorizedWake: interactionWake
    )
    if case .started(let start) = speechStart {
        require(start.speechStartedAtNS == 1_740_000_000, "speech analysis lookback changed")
    } else {
        require(false, "authorized contact failed to start a speech turn")
    }
    let speechFinish = speechSegmenter.observe(voiceActive: false, at: 2_700_000_000)
    if case .finished(let finish) = speechFinish {
        require(finish.reason == .voiceOffset, "speech turn closed for the wrong reason")
    } else {
        require(false, "voice offset failed to close the speech turn")
    }
} catch {
    require(false, "explicit contact interaction handoff failed: \(error)")
}
let localSafety = importanceDecision(
    "local-safety",
    EventImportanceFeatures(
        explicitContact: 1,
        urgency: 1,
        safetyRisk: 1,
        humanPresence: 1
    )
)
require(localSafety.recommendedRoute == .stayL0, "immediate protection escaped L0")
require(localSafety.distribution.requestHumanInteraction == 0, "local safety could open human interaction")
let importanceLabels = [
    LabelledEventImportanceExample(
        id: "quiet",
        partition: .calibration,
        expectedRoute: .stayL0,
        features: EventImportanceFeatures(interruptionCost: 0.8)
    ),
    LabelledEventImportanceExample(
        id: "novel",
        partition: .calibration,
        expectedRoute: .wakeL1,
        features: EventImportanceFeatures(novelty: 1, predictionError: 0.9, informationGain: 0.9)
    ),
    LabelledEventImportanceExample(
        id: "contact",
        partition: .calibration,
        expectedRoute: .requestHumanInteraction,
        features: EventImportanceFeatures(explicitContact: 1, socialSalience: 1, humanPresence: 1)
    ),
]
do {
    let importanceMetrics = try EventImportanceEvaluator.evaluate(
        model: importanceModel,
        examples: importanceLabels
    )
    require(importanceMetrics.unauthorizedHumanInteractionRequests == 0, "event evaluation admitted an unauthorized interaction")
    let fittedTemperature = try EventImportanceEvaluator.calibratedTemperature(
        parameters: .bootstrap,
        examples: importanceLabels
    )
    let calibratedParameters = try EventImportanceParameters.bootstrap.withTemperature(fittedTemperature)
    let calibratedMetrics = try EventImportanceEvaluator.evaluate(
        model: EventImportanceModel(parameters: calibratedParameters),
        examples: importanceLabels
    )
    require(
        calibratedMetrics.negativeLogLikelihood <= importanceMetrics.negativeLogLikelihood + 1e-12,
        "temperature calibration increased calibration loss"
    )
} catch {
    require(false, "event importance evaluation failed: \(error)")
}

do {
    for layer in CognitiveControlLayer.allCases {
        let embodimentRequest = CognitiveEmbodimentRequest(
            requestID: "core-check:\(layer.rawValue)",
            layer: layer,
            reason: "bounded semantic tracking goal",
            evidenceIDs: ["core-check:scene"],
            lease: EmbodimentLease(
                ownerID: "owner:\(layer.rawValue)",
                priority: 50,
                issuedAtNS: l1AuxiliaryStart,
                durationMilliseconds: 5_000,
                cancellationToken: "cancel:\(layer.rawValue)"
            ),
            operation: .trackTarget(
                TrackTargetGoal(
                    targetReference: "target:core-check",
                    reacquireIfOccluded: true,
                    motionStyle: .smooth
                )
            )
        )
        try embodimentRequest.validate()
    }
    let attentionPolicy = AttentionPolicyGoal(
        targets: [
            TargetAttentionDirective(
                targetReference: "target:person",
                selectionLogPrior: 2,
                trackingCommitment: 1
            ),
            TargetAttentionDirective(
                targetReference: "target:object",
                selectionLogPrior: -1,
                trackingCommitment: 0.2
            ),
        ]
    )
    require(
        abs(attentionPolicy.normalizedTargetPriors.values.reduce(0, +) - 1) < 1e-12,
        "cognitive target priors do not normalize"
    )
    let explorationPolicy = ExplorationPolicyGoal(
        mode: .directedSurvey,
        preferredDirections: [
            DirectionalPreference(
                bearing: GimbalRelativeBearing(azimuthDegrees: -45, elevationDegrees: 0),
                concentration: 4,
                weight: 3
            ),
            DirectionalPreference(
                bearing: GimbalRelativeBearing(azimuthDegrees: 45, elevationDegrees: 10),
                concentration: 2,
                weight: 1
            ),
        ]
    )
    require(
        explorationPolicy.normalizedDirectionWeights == [0.75, 0.25],
        "cognitive exploration directions do not normalize"
    )
    let motorNow: UInt64 = 70_000_000_000
    let motorArbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
    var motorCoordinator = EmbodimentMotorCoordinator()
    let motorRequest = CognitiveEmbodimentRequest(
        requestID: "core-check:motor-orient",
        layer: .l1,
        reason: "verify leased L0 motor handoff",
        evidenceIDs: ["core-check:spatial-goal"],
        lease: EmbodimentLease(
            ownerID: "owner:l1-motor",
            priority: 60,
            issuedAtNS: motorNow,
            durationMilliseconds: 100,
            cancellationToken: "cancel:core-check-motor"
        ),
        operation: .orient(OrientGoal(
            bearing: GimbalRelativeBearing(azimuthDegrees: 18, elevationDegrees: 3),
            motionStyle: .smooth
        ))
    )
    let motorDecision = motorArbiter.submit(motorRequest, at: motorNow)
    require(
        motorDecision.snapshot.physicalActuationEnabled
            && motorDecision.snapshot.mode == "active",
        "physical embodiment arbiter did not expose its explicit opt-in state"
    )
    if case let .orient(requestID, bearing, _, _, _, _) = motorCoordinator.apply(
        request: motorRequest,
        decision: motorDecision,
        at: motorNow
    ) {
        require(
            requestID == motorRequest.requestID && bearing.azimuthDegrees == 18,
            "accepted orientation changed before reaching L0"
        )
    } else {
        require(false, "accepted orientation did not become an L0 motor intent")
    }
    require(
        motorCoordinator.expire(at: motorNow + 99_000_000) == nil,
        "cognitive motor lease expired early"
    )
    require(
        motorCoordinator.expire(at: motorNow + 100_000_000)
            == .release(requestID: motorRequest.requestID, reason: "lease_expired"),
        "cognitive motor lease did not release at its exact deadline"
    )
    let captureRequest = CognitiveEmbodimentRequest(
        requestID: "core-check:capture-view",
        layer: .l1,
        reason: "capture one settled contextual view",
        evidenceIDs: ["core-check:spatial-goal"],
        lease: EmbodimentLease(
            ownerID: "owner:l1-motor",
            priority: 60,
            issuedAtNS: motorNow + 200_000_000,
            durationMilliseconds: 5_000,
            cancellationToken: "cancel:core-check-capture"
        ),
        operation: .captureView(CaptureViewGoal(
            bearing: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: 5),
            fieldOfViewDegrees: 45
        ))
    )
    let captureDecision = motorArbiter.submit(captureRequest, at: motorNow + 200_000_000)
    if case let .capture(requestID, _, _, bearing, fieldOfView, _) = motorCoordinator.apply(
        request: captureRequest,
        decision: captureDecision,
        at: motorNow + 200_000_000
    ) {
        require(
            requestID == captureRequest.requestID
                && bearing.azimuthDegrees == -20
                && fieldOfView == 45,
            "capture view lost its requested spatial framing"
        )
    } else {
        require(false, "capture view did not become a distinct L0 sensory-motor intent")
    }
    require(
        motorArbiter.completeMotorGoal(
            requestID: captureRequest.requestID,
            at: motorNow + 200_000_001
        ),
        "one-shot capture did not complete its arbiter goal"
    )
    require(
        motorCoordinator.complete(requestID: captureRequest.requestID)
            == .release(requestID: captureRequest.requestID, reason: "capture_completed"),
        "one-shot capture did not release L0 motor authority"
    )
} catch {
    require(false, "cognitive embodiment contract failed: \(error)")
}

let rotationDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("soma-core-rotation-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: rotationDirectory) }
let rotationBaseURL = rotationDirectory.appendingPathComponent("detail.jsonl")
let rotationPolicy = JSONLRotationPolicy(maximumBytes: 2, retainedFiles: 2)
do {
    let firstStore = try RotatingJSONLStore(baseURL: rotationBaseURL, policy: rotationPolicy)
    for value in ["a\n", "b\n", "c\n", "d\n"] {
        try firstStore.write(Data(value.utf8))
    }
    try firstStore.close()
    var segments = try RotatingJSONLStore.segmentURLs(for: rotationBaseURL)
    require(segments.count == 2, "rotating JSONL store did not cap segment count")
    let firstRetained = try String(contentsOf: segments[0], encoding: .utf8)
    let secondRetained = try String(contentsOf: segments[1], encoding: .utf8)
    require(firstRetained == "c\n", "rotating JSONL store retained an old segment")
    require(secondRetained == "d\n", "rotating JSONL store lost the newest segment")

    let restartedStore = try RotatingJSONLStore(baseURL: rotationBaseURL, policy: rotationPolicy)
    try restartedStore.write(Data("e\n".utf8))
    try restartedStore.close()
    segments = try RotatingJSONLStore.segmentURLs(for: rotationBaseURL)
    require(segments.count == 2, "rotating JSONL store exceeded retention after restart")
    let restartedFirst = try String(contentsOf: segments[0], encoding: .utf8)
    let restartedSecond = try String(contentsOf: segments[1], encoding: .utf8)
    require(restartedFirst == "d\n", "restart retention discarded the wrong segment")
    require(restartedSecond == "e\n", "restart retention did not create a new segment")
} catch {
    require(false, "rotating JSONL store failed: \(error.localizedDescription)")
}

let memoryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("soma-core-memory-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: memoryDirectory) }
do {
    let memoryKey = try CognitiveMemoryEncryptionKey(
        rawRepresentation: Data((0 ..< 32).map { UInt8($0) })
    )
    let memoryStart = Date(timeIntervalSince1970: 10_000)
    let personID = UUID()
    let memoryStore = try CognitiveMemoryStore(directoryURL: memoryDirectory, encryptionKey: memoryKey)
    let inserted = try await memoryStore.insert(
        CognitiveMemoryDraft(
            tier: .mediumTerm,
            summary: "A known collaborator prefers concise status summaries",
            payload: .personFact(
                PersonFactMemory(personEntityID: personID, key: "status_style", value: "concise")
            ),
            confidence: 1,
            provenance: [
                MemoryProvenance(
                    source: .explicitUser,
                    sourceID: "core-check:user",
                    observedAt: memoryStart,
                    evidenceIDs: ["core-check:turn"]
                )
            ],
            sensitivity: .personal,
            disclosure: .remoteSummaryAllowed,
            expiresAt: memoryStart.addingTimeInterval(30 * 24 * 60 * 60)
        ),
        at: memoryStart
    )
    let journalURL = memoryDirectory.appendingPathComponent(CognitiveMemoryStore.journalFilename)
    let encryptedJournal = try Data(contentsOf: journalURL)
    let memoryDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: memoryDirectory.path)
    let memoryJournalAttributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
    let memoryDirectoryPermissions = (memoryDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue
    let memoryJournalPermissions = (memoryJournalAttributes[.posixPermissions] as? NSNumber)?.intValue
    require(memoryDirectoryPermissions == 0o700, "cognitive memory directory permissions are not private")
    require(memoryJournalPermissions == 0o600, "cognitive memory journal permissions are not private")
    require(
        !String(decoding: encryptedJournal, as: UTF8.self).contains(inserted.summary),
        "cognitive memory journal persisted plaintext"
    )
    let correctedAt = memoryStart.addingTimeInterval(60)
    let corrected = try await memoryStore.correct(
        id: inserted.id,
        replacement: CognitiveMemoryDraft(
            tier: .mediumTerm,
            summary: "The collaborator explicitly confirmed concise status summaries",
            payload: inserted.payload,
            confidence: 1,
            provenance: [
                MemoryProvenance(
                    source: .explicitUser,
                    sourceID: "core-check:user",
                    observedAt: correctedAt,
                    evidenceIDs: ["core-check:confirmation"]
                )
            ],
            sensitivity: .personal,
            disclosure: .remoteSummaryAllowed,
            expiresAt: correctedAt.addingTimeInterval(30 * 24 * 60 * 60)
        ),
        reason: "explicit correction",
        at: correctedAt
    )
    require(corrected.revision == 2, "cognitive memory correction did not advance its revision")
    let promotedAt = memoryStart.addingTimeInterval(120)
    let promoted = try await memoryStore.promote(
        id: inserted.id,
        to: .longTerm,
        expiresAt: nil,
        provenance: [
            MemoryProvenance(
                source: .consolidation,
                sourceID: "core-check:consolidation",
                observedAt: promotedAt,
                evidenceIDs: [inserted.id.uuidString]
            )
        ],
        reason: "explicit fact consolidated",
        at: promotedAt
    )
    require(promoted.revision == 3, "cognitive memory promotion did not preserve revision history")
    let memoryHistory = try await memoryStore.history(id: inserted.id)
    require(memoryHistory.map(\.revision) == [1, 2, 3], "cognitive memory revision history is incomplete")
    let projections = try await memoryStore.remoteProjection(
        .init(relatedTo: [personID]),
        at: promotedAt
    )
    require(projections.map(\.id) == [inserted.id], "memory projection lost an allowed summary")
    let expiring = try await memoryStore.insert(
        CognitiveMemoryDraft(
            tier: .shortTerm,
            summary: "Transient presence",
            payload: .situation(SituationMemory(state: "person_present")),
            confidence: 0.8,
            provenance: [
                MemoryProvenance(
                    source: .sensorSummary,
                    sourceID: "core-check:l0",
                    observedAt: promotedAt,
                    evidenceIDs: ["core-check:presence"]
                )
            ],
            expiresAt: promotedAt.addingTimeInterval(1)
        ),
        at: promotedAt
    )
    let expiredIDs = try await memoryStore.purgeExpired(at: promotedAt.addingTimeInterval(2))
    require(expiredIDs == [expiring.id], "cognitive memory retention did not purge the expired record")
    do {
        _ = try CognitiveMemoryStore(directoryURL: memoryDirectory, encryptionKey: memoryKey)
        require(false, "cognitive memory admitted a second writer")
    } catch let error as CognitiveMemoryError {
        require(error == .storeLocked, "cognitive memory returned the wrong second-writer error")
    }
    do {
        _ = try await memoryStore.insert(
            CognitiveMemoryDraft(
                tier: .longTerm,
                summary: "Ungrounded durable model inference",
                payload: .situation(SituationMemory(state: "unconfirmed")),
                confidence: 0.7,
                provenance: [
                    MemoryProvenance(
                        source: .l1Inference,
                        sourceID: "core-check:l1",
                        observedAt: memoryStart,
                        evidenceIDs: ["core-check:frame"]
                    )
                ]
            ),
            at: memoryStart
        )
        require(false, "direct L1 inference entered long-term memory")
    } catch let error as CognitiveMemoryError {
        if case .validationFailed = error {
            // Expected: long-term writes require an authorized durable source.
        } else {
            require(false, "cognitive memory returned the wrong durable-write error")
        }
    }
    try await memoryStore.close()

    let wrongMemoryKey = try CognitiveMemoryEncryptionKey(
        rawRepresentation: Data(repeating: 0xFF, count: 32)
    )
    do {
        _ = try CognitiveMemoryStore(directoryURL: memoryDirectory, encryptionKey: wrongMemoryKey)
        require(false, "cognitive memory accepted the wrong encryption key")
    } catch let error as CognitiveMemoryError {
        if case .corruptJournal = error {
            // Expected: AES-GCM authentication rejects the journal.
        } else {
            require(false, "cognitive memory returned the wrong authentication error")
        }
    }

    let reopenedMemory = try CognitiveMemoryStore(directoryURL: memoryDirectory, encryptionKey: memoryKey)
    let restoredMemory = try await reopenedMemory.record(id: inserted.id, at: promotedAt)
    require(
        restoredMemory == promoted,
        "cognitive memory did not survive encrypted journal replay"
    )
    try await reopenedMemory.delete(id: inserted.id, reason: "core check deletion", at: promotedAt)
    let deletedMemory = try await reopenedMemory.record(id: inserted.id, at: promotedAt)
    require(
        deletedMemory == nil,
        "deleted cognitive memory remained queryable"
    )
    try await reopenedMemory.close()
    let deletedJournal = try Data(contentsOf: journalURL)
    require(deletedJournal.isEmpty, "deletion retained the record in the active journal")
} catch {
    require(false, "cognitive memory store failed: \(error)")
}
print("soma-core-check: PASS")
