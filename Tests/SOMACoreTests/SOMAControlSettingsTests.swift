#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class SOMAControlSettingsTests: XCTestCase {
    func testOwnerOnlySettingsPersistRuntimeChoicesAndAdministratorMapping() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-control-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let administrator = SOMAAdministratorIdentity(
            entityID: UUID(),
            displayName: "SOMA Owner",
            preferredAddress: "Chief"
        )
        let expected = SOMAControlSettings(
            realtimeVoiceEnabled: true,
            realtimeVoice: .maple,
            led: .init(responseMode: .contextual, brightness: 3),
            nativeHumanTrackingEnabled: true,
            autonomousExplorationEnabled: false,
            administrator: administrator
        )
        let store = SOMAControlSettingsStore(fileURL: file)

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
    }

    func testLEDPolicyKeepsReactionBoundedToItsConfiguredStates() {
        XCTAssertTrue(SOMALEDResponseMode.expressive.permits(.exploring))
        XCTAssertFalse(SOMALEDResponseMode.contextual.permits(.humanDetected))
        XCTAssertTrue(SOMALEDResponseMode.contextual.permits(.conversation))
        XCTAssertFalse(SOMALEDResponseMode.quiet.permits(.working))
        XCTAssertTrue(SOMALEDResponseMode.quiet.permits(.conversation))
        XCTAssertFalse(SOMALEDResponseMode.off.permits(.conversation))
    }

    func testLEDSignalsPersistPerStateColorAndCadence() throws {
        var settings = SOMAControlSettings()
        settings.led.signals[.conversation] = .init(color: .green, pattern: .steady)

        let decoded = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.led.signal(for: .conversation).color, .green)
        XCTAssertEqual(decoded.led.signal(for: .conversation).pattern, .steady)
        XCTAssertEqual(decoded.led.signal(for: .exploring).color, .yellow)
        XCTAssertEqual(decoded.led.signal(for: .exploring).pattern, .steady)
        XCTAssertEqual(SOMALEDColor.yellow.displayName, "Yellow")
        XCTAssertEqual(SOMALEDColor.green.displayName, "Green")
        XCTAssertEqual(SOMALEDColor.blue.firmwareStateID, 57)
        XCTAssertEqual(decoded.led.signal(for: .contactReady).firmwareStateID, 18)
    }

    func testVersionOneSettingsMigrateToStateSignals() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "realtimeVoiceEnabled": true,
          "realtimeVoice": "maple",
          "led": { "responseMode": "contextual", "brightness": 3 },
          "nativeHumanTrackingEnabled": true,
          "autonomousExplorationEnabled": false
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.schemaVersion, SOMAControlSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.led.signals.count, SubconsciousIndicatorState.configurationStates.count)
        XCTAssertEqual(migrated.led.signal(for: .conversation).color, .blue)
        XCTAssertEqual(migrated.led.signal(for: .conversation).pattern, .steady)
    }

    func testVersionTwoPresetSettingsMigrateToVisibleColorAndReadyBlink() throws {
        let legacy = """
        {
          "schemaVersion": 2,
          "led": {
            "responseMode": "expressive",
            "brightness": 2,
            "signals": [
              "contact_ready",
              { "preset": "tracking", "pattern": "doubleBlink" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.schemaVersion, 5)
        XCTAssertEqual(migrated.led.signal(for: .contactReady).color, .blue)
        XCTAssertEqual(migrated.led.signal(for: .contactReady).pattern, .blink)
    }

    func testUnsupportedHostCadenceMigratesToVerifiedSteadyDeviceState() throws {
        let legacy = """
        {
          "schemaVersion": 3,
          "led": {
            "signals": [
              "working",
              { "color": "green", "pattern": "heartbeat" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.led.signal(for: .working).color, .green)
        XCTAssertEqual(migrated.led.signal(for: .working).pattern, .steady)
    }

    func testLegacyListeningAndSpeakingMigrateToOneConversationSignal() throws {
        let legacy = """
        {
          "schemaVersion": 4,
          "led": {
            "signals": [
              "listening",
              { "color": "blue", "pattern": "steady" },
              "speaking",
              { "color": "green", "pattern": "steady" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.led.signals.count, SubconsciousIndicatorState.configurationStates.count)
        XCTAssertEqual(migrated.led.signal(for: .conversation).color, .green)
        XCTAssertNil(migrated.led.signals[.listening])
        XCTAssertNil(migrated.led.signals[.speaking])
    }
}
#endif
