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
        XCTAssertEqual(evidence[0].windowStartNS, 0)
        XCTAssertEqual(evidence[0].windowEndNS, 260_000_000)
    }

    func testSplitInputRetainsTheClassifiedWindowStartTimestamp() throws {
        let detector = try NeuralVoiceActivityDetector()
        let chunkSamples = 1_040
        var evidence: [NeuralVoiceActivityEvidence] = []
        for index in 1...4 {
            evidence += try detector.ingest(
                samples: Array(repeating: 0, count: chunkSamples),
                sampleRateHz: NeuralVoiceActivityDetector.targetSampleRateHz,
                continuous: index > 1,
                at: UInt64(index) * 65_000_000,
                durationNS: 65_000_000
            )
        }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].windowStartNS, 0)
        XCTAssertEqual(evidence[0].windowEndNS, 260_000_000)
    }

    func testDiscontinuityOffsetEndsBeforeReplacementFrameAndFrameIsReclassified() throws {
        let detector = try NeuralVoiceActivityDetector(activationThreshold: 0)
        let window = Array(repeating: Float.zero, count: NeuralVoiceActivityDetector.windowSampleCount)
        let first = try detector.ingest(
            samples: window,
            sampleRateHz: NeuralVoiceActivityDetector.targetSampleRateHz,
            continuous: false,
            at: 260_000_000,
            durationNS: 260_000_000
        )
        XCTAssertTrue(first.last?.active == true)

        let replacement = try detector.ingest(
            samples: window,
            sampleRateHz: NeuralVoiceActivityDetector.targetSampleRateHz,
            continuous: false,
            at: 520_000_000,
            durationNS: 260_000_000
        )
        XCTAssertEqual(replacement.count, 2)
        XCTAssertTrue(replacement[0].discontinuityReset)
        XCTAssertFalse(replacement[0].active)
        XCTAssertEqual(replacement[0].windowEndNS, 260_000_000)
        XCTAssertTrue(replacement[1].active)
        XCTAssertEqual(replacement[1].windowStartNS, 260_000_000)
        XCTAssertEqual(replacement[1].windowEndNS, 520_000_000)
    }
}
#endif
