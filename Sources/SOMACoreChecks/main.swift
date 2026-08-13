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
let leftMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: rightDelayed, sampleRateHz: 32_000)
let centerMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: stereoSource, sampleRateHz: 32_000)
let rightMeasurement = StereoTDOAEstimator.measure(left: stereoSource, right: rightAdvanced, sampleRateHz: 32_000)
require(leftMeasurement?.lagSamples == 3, "TDOA did not recover a delayed right channel")
require(centerMeasurement?.lagSamples == 0, "TDOA did not recover a centered source")
require(rightMeasurement?.lagSamples == -3, "TDOA did not recover an advanced right channel")
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
require(leftDiagnostic.ambiguous == 1 && leftDiagnostic.lowEnergy == 1 && leftDiagnostic.invalidInput == 1, "calibration diagnostic lost rejection reasons")
require(calibrationDiagnostics.makeCalibration() != nil, "diagnostics could not produce a valid three-position calibration")
let uncalibratedDirection = StereoTDOAEstimator(calibration: nil).estimate(left: stereoSource, right: rightDelayed, sampleRateHz: 32_000)
require(uncalibratedDirection.direction == .unknown, "uncalibrated TDOA emitted a direction")
let calibratedEstimator = StereoTDOAEstimator(calibration: calibration)
require(calibratedEstimator.estimate(left: stereoSource, right: rightDelayed, sampleRateHz: 32_000).direction == AudioDirection.left, "calibrated TDOA did not identify left")
require(calibratedEstimator.estimate(left: stereoSource, right: stereoSource, sampleRateHz: 32_000).direction == AudioDirection.center, "calibrated TDOA did not identify center")
require(calibratedEstimator.estimate(left: stereoSource, right: rightAdvanced, sampleRateHz: 32_000).direction == AudioDirection.right, "calibrated TDOA did not identify right")
print("soma-core-check: PASS")
