import Foundation
import SOMACore

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("soma-core-check: \\(message)\\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private func rect(_ x: Double) -> NormalizedRect {
    NormalizedRect(x: x, y: 0.25, width: 0.20, height: 0.30)
}

let model = PredictiveWorldModel()
let start: UInt64 = 1_000_000_000
_ = model.ingestVisual(VisualObservation(rect: rect(0.30), confidence: 0.95, source: .detector), at: start)
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
let first = reordered.ingestVisual(VisualObservation(rect: rect(0.25), confidence: 0.90, source: .detector), at: start + 100_000_000)
let delayed = reordered.ingestVisual(VisualObservation(rect: rect(0.20), confidence: 0.90, source: .tracker), at: start + 50_000_000)
require(delayed.monotonicNS == start + 100_000_000, "out-of-order evidence reversed belief time")
require(delayed.target?.rect == first.target?.rect, "out-of-order evidence changed belief content")
print("soma-core-check: PASS")
