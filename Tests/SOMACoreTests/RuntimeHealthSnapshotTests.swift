import XCTest
@testable import SOMACore

final class RuntimeHealthSnapshotTests: XCTestCase {
    func testProjectionPolicyRetainsRecoveryAndStopWithoutSamplingNoise() {
        XCTAssertTrue(RuntimeHealthProjectionPolicy.retains(source: "face_neural_engine", state: "runtime_error"))
        XCTAssertTrue(RuntimeHealthProjectionPolicy.retains(source: "face_neural_engine", state: "recovered"))
        XCTAssertTrue(RuntimeHealthProjectionPolicy.retains(source: "attention_gimbal_bridge", state: "stopped"))
        XCTAssertTrue(RuntimeHealthProjectionPolicy.retains(source: "social_indicator", state: "exploring"))
        XCTAssertTrue(RuntimeHealthProjectionPolicy.retains(
            source: "obsbot_control_transport",
            state: "awaiting_physical_reconnect"
        ))
        XCTAssertTrue(RuntimeHealthProjectionPolicy.retains(
            source: "obsbot_control_transport",
            state: "healthy"
        ))
        XCTAssertFalse(RuntimeHealthProjectionPolicy.retains(source: "l2_live_voice", state: "failed"))
        XCTAssertFalse(RuntimeHealthProjectionPolicy.retains(source: "face_identity", state: "alignments"))
        XCTAssertFalse(RuntimeHealthProjectionPolicy.retains(source: "attention_gimbal_bridge", state: "coverage_direction_sampled"))
    }

    func testStorePersistsOnlySemanticStateChanges() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runtime-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime-health.json")
        let generation = UUID()
        let store = try RuntimeHealthSnapshotStore(
            fileURL: url,
            generationID: generation,
            processID: 42,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(try store.update(source: "control_settings", state: "loaded", monotonicNS: 10))
        XCTAssertFalse(try store.update(source: "control_settings", state: "loaded", monotonicNS: 20))
        XCTAssertFalse(try store.update(source: "control_settings", state: "rejected", monotonicNS: 9))
        XCTAssertFalse(try store.update(source: "control_settings", state: "rejected", monotonicNS: 15))

        let snapshot = try RuntimeHealthSnapshot.load(from: url)
        XCTAssertEqual(snapshot.generationID, generation)
        XCTAssertEqual(snapshot.processID, 42)
        XCTAssertEqual(snapshot.sources["control_settings"], .init(state: "loaded", monotonicNS: 10))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testNewRuntimeGenerationClearsStaleSourceState() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runtime-health-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime-health.json")

        let first = try RuntimeHealthSnapshotStore(fileURL: url, processID: 11)
        try first.update(source: "social_indicator", state: "conversation", monotonicNS: 10)
        _ = try RuntimeHealthSnapshotStore(fileURL: url, processID: 12)

        let snapshot = try RuntimeHealthSnapshot.load(from: url)
        XCTAssertEqual(snapshot.processID, 12)
        XCTAssertTrue(snapshot.sources.isEmpty)
    }

    func testFailedPersistenceDoesNotConsumeTheStateTransition() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runtime-health-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime-health.json")
        let store = try RuntimeHealthSnapshotStore(fileURL: url, processID: 23)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.update(source: "control_settings", state: "loaded", monotonicNS: 10))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        XCTAssertTrue(try store.update(source: "control_settings", state: "loaded", monotonicNS: 10))
        XCTAssertEqual(
            try RuntimeHealthSnapshot.load(from: url).sources["control_settings"],
            .init(state: "loaded", monotonicNS: 10)
        )
    }
}
