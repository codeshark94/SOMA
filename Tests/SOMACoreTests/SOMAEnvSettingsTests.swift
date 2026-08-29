import XCTest
@testable import SOMACore

final class SOMAEnvSettingsTests: XCTestCase {
    func testEnvStoreRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "envstore-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")

        let settings = SOMAEnvSettings(
            ollamaAPIKey: "sk-test-123",
            ollamaHost: "http://192.168.1.5:11434",
            l1Model: "gemma4:31b-cloud",
            l0TrackingEnabled: false,
            l0ExploreEnabled: true,
            l1ReasoningCadenceSeconds: 180,
            l1CuriosityCollectionEnabled: true,
            l1CollectionIntervalHours: 6,
            l2ProactiveOpeningsEnabled: false
        )
        let store = SOMAEnvStore(fileURL: url)
        try store.save(settings)
        let loaded = try store.load()
        XCTAssertEqual(loaded, settings)

        // Hand-edit tolerance: missing keys fall back to defaults.
        try store.save(.init())
        let defaults = try store.load()
        XCTAssertEqual(defaults.ollamaHost, "http://127.0.0.1:11434")
        XCTAssertEqual(defaults.l1ReasoningCadenceSeconds, 150)
        XCTAssertTrue(defaults.l1CuriosityCollectionEnabled)
        XCTAssertEqual(defaults.l1CollectionIntervalHours, 24)
        XCTAssertEqual(defaults.l0EyeContactPupilThreshold, 0.9)
    }

    func testEnvStoreMigratesLegacyReasoningCadence() throws {
        let dir = NSTemporaryDirectory() + "envstore-legacy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        try "SOMA_L1_IDLE_CADENCE_SECONDS=180\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let loaded = try SOMAEnvStore(fileURL: url).load()

        XCTAssertEqual(loaded.l1ReasoningCadenceSeconds, 180)
    }

    func testEnvStorePreservesRuntimeAndHardwareAssignments() throws {
        let dir = NSTemporaryDirectory() + "envstore-runtime-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        try """
        OLLAMA_HOST=http://old-host:11434
        SOMA_VIDEO_ID=auto
        SOMA_AUDIO_ID=auto
        SOMA_ENABLE_MOTION=0
        SOMA_ENABLE_L2_LIVE_VOICE=0
        SOMA_L05_VLM_MODEL="/path with spaces/model"
        SOMA_L1_IDLE_CADENCE_SECONDS=90
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let store = SOMAEnvStore(fileURL: url)
        var settings = try store.load()
        settings.ollamaHost = "http://new-host:11434"
        try store.save(settings)

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("OLLAMA_HOST=http://new-host:11434"))
        XCTAssertTrue(saved.contains("SOMA_VIDEO_ID=auto"))
        XCTAssertTrue(saved.contains("SOMA_AUDIO_ID=auto"))
        XCTAssertTrue(saved.contains("SOMA_ENABLE_MOTION=0"))
        XCTAssertTrue(saved.contains("SOMA_ENABLE_L2_LIVE_VOICE=0"))
        XCTAssertTrue(saved.contains("SOMA_L05_VLM_MODEL=\"/path with spaces/model\""))
        XCTAssertFalse(saved.contains("SOMA_L1_IDLE_CADENCE_SECONDS"))
    }
}
