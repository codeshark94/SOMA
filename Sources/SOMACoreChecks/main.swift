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
_ = model.ingestVisual(VisualObservation(rect: rect(0.30), confidence: 0.95, source: .faceDetector), at: start)
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
let first = reordered.ingestVisual(VisualObservation(rect: rect(0.25), confidence: 0.90, source: .faceDetector), at: start + 100_000_000)
let delayed = reordered.ingestVisual(VisualObservation(rect: rect(0.20), confidence: 0.90, source: .tracker), at: start + 50_000_000)
require(delayed.monotonicNS == start + 100_000_000, "out-of-order evidence reversed belief time")
require(delayed.target?.rect == first.target?.rect, "out-of-order evidence changed belief content")

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
print("soma-core-check: PASS")
