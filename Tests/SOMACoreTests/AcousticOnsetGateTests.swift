#if canImport(XCTest)
import XCTest
@testable import SOMACore

final class AcousticOnsetGateTests: XCTestCase {
    func testSharpNonSpeechTransientTriggersAfterAmbientSettles() {
        let gate = AcousticOnsetGate()
        var now: UInt64 = 10_000_000
        for _ in 0..<60 {
            let evidence = gate.ingest(
                levelDB: -32,
                durationNS: 10_000_000,
                continuous: true,
                at: now
            )
            XCTAssertFalse(evidence.triggered)
            now += 10_000_000
        }

        let evidence = gate.ingest(
            levelDB: -13,
            durationNS: 10_000_000,
            continuous: true,
            at: now
        )

        XCTAssertTrue(evidence.triggered)
        XCTAssertTrue(evidence.transient)
    }

    func testOrdinaryAmbientVariationDoesNotTrigger() {
        let gate = AcousticOnsetGate()
        var now: UInt64 = 10_000_000
        for _ in 0..<60 {
            _ = gate.ingest(
                levelDB: -32,
                durationNS: 10_000_000,
                continuous: true,
                at: now
            )
            now += 10_000_000
        }

        for level in [-31.0, -29.0, -33.0, -30.0] {
            let evidence = gate.ingest(
                levelDB: level,
                durationNS: 10_000_000,
                continuous: true,
                at: now
            )
            XCTAssertFalse(evidence.triggered)
            now += 10_000_000
        }
    }

    func testSustainedSoundTriggersWithoutSpeechClassification() {
        let gate = AcousticOnsetGate()
        var now: UInt64 = 10_000_000
        for _ in 0..<60 {
            _ = gate.ingest(
                levelDB: -32,
                durationNS: 10_000_000,
                continuous: true,
                at: now
            )
            now += 10_000_000
        }

        XCTAssertFalse(gate.ingest(
            levelDB: -23,
            durationNS: 10_000_000,
            continuous: true,
            at: now
        ).triggered)
        now += 10_000_000
        XCTAssertFalse(gate.ingest(
            levelDB: -23,
            durationNS: 10_000_000,
            continuous: true,
            at: now
        ).triggered)
        now += 10_000_000
        XCTAssertTrue(gate.ingest(
            levelDB: -23,
            durationNS: 10_000_000,
            continuous: true,
            at: now
        ).triggered)
    }

    func testCooldownPreventsOneSoundFromBecomingRepeatedOnsets() {
        let gate = AcousticOnsetGate()
        var now: UInt64 = 10_000_000
        for _ in 0..<60 {
            _ = gate.ingest(
                levelDB: -32,
                durationNS: 10_000_000,
                continuous: true,
                at: now
            )
            now += 10_000_000
        }
        XCTAssertTrue(gate.ingest(
            levelDB: -13,
            durationNS: 10_000_000,
            continuous: true,
            at: now
        ).triggered)
        now += 20_000_000
        XCTAssertFalse(gate.ingest(
            levelDB: -12,
            durationNS: 10_000_000,
            continuous: true,
            at: now
        ).triggered)
    }
}
#endif
