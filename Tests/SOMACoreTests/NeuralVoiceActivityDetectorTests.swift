#if canImport(XCTest)
import XCTest
@testable import SOMAVADModel

final class NeuralVoiceActivityDetectorTests: XCTestCase {
    func testSilentWindowProducesBoundedCoreMLVADProbability() throws {
        let detector = try NeuralVoiceActivityDetector()
        let evidence = try detector.ingest(
            samples: Array(repeating: 0, count: NeuralVoiceActivityDetector.windowSampleCount),
            sampleRateHz: NeuralVoiceActivityDetector.targetSampleRateHz,
            continuous: false,
            at: 260_000_000
        )

        XCTAssertEqual(evidence.count, 1)
        XCTAssertGreaterThanOrEqual(evidence[0].probability, 0)
        XCTAssertLessThanOrEqual(evidence[0].probability, 1)
        XCTAssertFalse(evidence[0].active)
    }
}
#endif
