#if canImport(XCTest)
import XCTest
@testable import SOMACore

final class PredictiveWorldModelTests: XCTestCase {
    func testVoiceReweightsPersistentVisualTargetTowardReadyInteraction() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 1_000_000_000
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                confidence: 0.95,
                source: .neuralFaceDetector
            ),
            at: start
        )
        let belief = model.ingestVoice(active: true, confidence: 0.95, at: start + 20_000_000)

        XCTAssertEqual(belief.targetStatus, .tracked)
        XCTAssertGreaterThan(belief.readyProbability, belief.observingProbability)
        XCTAssertEqual(belief.policy, .handoffCandidate)
    }

    func testPredictionRetainsTargetBrieflyThenReportsLoss() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 2_000_000_000
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
                confidence: 0.9,
                source: .neuralFaceDetector
            ),
            at: start
        )
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.2),
                confidence: 0.9,
                source: .tracker
            ),
            at: start + 100_000_000
        )

        let predicted = model.snapshot(at: start + 300_000_000)
        XCTAssertEqual(predicted.targetStatus, .tracked)
        XCTAssertGreaterThan(predicted.target?.velocityX ?? 0, 0)

        let lost = model.snapshot(at: start + 2_000_000_000)
        XCTAssertEqual(lost.targetStatus, .none)
        XCTAssertEqual(lost.policy, .hold)
    }

    func testBeliefProbabilitiesRemainNormalized() {
        let model = PredictiveWorldModel()
        let belief = model.snapshot(at: 3_000_000_000)
        XCTAssertEqual(
            belief.idleProbability + belief.observingProbability + belief.readyProbability,
            1,
            accuracy: 0.000_001
        )
    }
}
#endif
