import Foundation

/// The voices accepted by the account-backed realtime helper. Keeping this
/// contract in the core target lets the launcher and the control surface agree
/// on a value before a session is opened.
public enum SOMARealtimeVoice: String, CaseIterable, Codable, Sendable {
    case alloy
    case arbor
    case ash
    case ballad
    case breeze
    case cedar
    case coral
    case cove
    case echo
    case ember
    case juniper
    case maple
    case marin
    case sage
    case shimmer
    case sol
    case spruce
    case vale
    case verse

    public var displayName: String { rawValue.capitalized }
}

/// A presentation policy for the OBSBOT's built-in indicator. The device
/// owns its colour palette; SOMA selects when and how prominently it reacts.
public enum SOMALEDResponseMode: String, CaseIterable, Codable, Sendable {
    case expressive
    case contextual
    case quiet
    case off

    public var displayName: String {
        switch self {
        case .expressive: "Expressive"
        case .contextual: "Contextual"
        case .quiet: "Quiet"
        case .off: "Off"
        }
    }

    public func permits(_ state: SubconsciousIndicatorState) -> Bool {
        switch self {
        case .expressive:
            true
        case .contextual:
            state != .exploring && state != .humanDetected
        case .quiet:
            state.configurationState == .conversation
        case .off:
            false
        }
    }
}

/// A user-facing colour available from the Tiny 2 Lite indicator. There is no
/// public RGB API, so these map to the physically verified device palette.
public enum SOMALEDColor: String, CaseIterable, Codable, Sendable {
    case yellow
    case blue
    case green

    public var displayName: String { rawValue.capitalized }

    /// State 57 is the physically verified steady-blue device state.
    public var firmwareStateID: Int {
        switch self {
        case .yellow: 16
        case .blue: 57
        case .green: 54
        }
    }
}

/// Internal calibration entries for the Tiny 2 Lite. These describe the
/// firmware's state IDs and are deliberately kept out of the user settings
/// surface: names such as `tracking` are device implementation details, not
/// meaningful LED choices.
public enum SOMALEDFirmwarePreset: String, CaseIterable, Codable, Sendable {
    case targetLost
    case targetLock
    case gesture
    case normalWork
    case tracking

    public var colorName: String {
        switch self {
        case .targetLost: "Yellow"
        case .targetLock, .gesture, .tracking: "Blue"
        case .normalWork: "Green"
        }
    }

    public var hasFirmwareBlink: Bool {
        if case .gesture = self { return true }
        return false
    }

    /// The native bridge validates this small fixed set before it ever reaches
    /// the device SDK. The firmware maps each entry to its own RGB palette.
    public var firmwareStateID: Int {
        switch self {
        case .targetLost: 16
        case .targetLock: 17
        case .gesture: 18
        case .normalWork: 54
        case .tracking: 57
        }
    }
}

public enum SOMALEDPattern: String, CaseIterable, Codable, Sendable {
    case steady
    case beacon
    case doubleBlink
    case longPulse
    case heartbeat
    case blink

    public var displayName: String {
        switch self {
        case .steady: "Steady"
        case .beacon: "Beacon"
        case .doubleBlink: "Double blink"
        case .longPulse: "Long pulse"
        case .heartbeat: "Heartbeat"
        case .blink: "Blink"
        }
    }

    /// The Tiny 2 Lite exposes only a steady indicator plus one physically
    /// verified continuous blue firmware blink. Its state-clear API accepts
    /// commands but does not produce a reliable visible off phase, so host
    /// cadence names are retained only to migrate old settings safely.
    public func isPhysicallySupported(for color: SOMALEDColor) -> Bool {
        self == .steady || (self == .blink && color == .blue)
    }

    public var indicatorPattern: SubconsciousIndicatorPattern {
        switch self {
        case .steady:
            .init(name: "steady", phases: [
                .init(illuminated: true, durationMilliseconds: nil),
            ])
        case .beacon:
            .init(name: "beacon", phases: [
                .init(illuminated: true, durationMilliseconds: 180),
                .init(illuminated: false, durationMilliseconds: 1_320),
            ])
        case .doubleBlink:
            .init(name: "double_blink", phases: [
                .init(illuminated: true, durationMilliseconds: 140),
                .init(illuminated: false, durationMilliseconds: 110),
                .init(illuminated: true, durationMilliseconds: 140),
                .init(illuminated: false, durationMilliseconds: 610),
            ])
        case .longPulse:
            .init(name: "long_pulse", phases: [
                .init(illuminated: true, durationMilliseconds: 800),
                .init(illuminated: false, durationMilliseconds: 200),
            ])
        case .heartbeat:
            .init(name: "heartbeat", phases: [
                .init(illuminated: true, durationMilliseconds: 300),
                .init(illuminated: false, durationMilliseconds: 700),
            ])
        case .blink:
            .init(name: "blink", phases: [
                .init(illuminated: true, durationMilliseconds: 400),
                .init(illuminated: false, durationMilliseconds: 400),
            ])
        }
    }
}

public struct SOMALEDSignalSettings: Codable, Equatable, Sendable {
    public var color: SOMALEDColor
    public var pattern: SOMALEDPattern

    public init(color: SOMALEDColor, pattern: SOMALEDPattern) {
        self.color = color
        self.pattern = pattern
    }

    public var usesFirmwareBlink: Bool {
        color == .blue && pattern == .blink
    }

    public var firmwareStateID: Int {
        usesFirmwareBlink
            ? SOMALEDFirmwarePreset.gesture.firmwareStateID
            : color.firmwareStateID
    }

    public func normalizedForDevice() -> Self {
        guard !pattern.isPhysicallySupported(for: color) else { return self }
        return .init(color: color, pattern: .steady)
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case pattern
        // Read-only migration key for settings schema 2.
        case preset
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try values.decode(SOMALEDPattern.self, forKey: .pattern)
        if let color = try values.decodeIfPresent(SOMALEDColor.self, forKey: .color) {
            self.color = color
            return
        }
        let legacyPreset = try values.decode(SOMALEDFirmwarePreset.self, forKey: .preset)
        switch legacyPreset {
        case .targetLost:
            color = .yellow
        case .normalWork:
            color = .green
        case .targetLock, .gesture, .tracking:
            color = .blue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(color, forKey: .color)
        try values.encode(pattern, forKey: .pattern)
    }
}

public enum SOMALEDHardwareCommand: Equatable, Sendable {
    case clear(stateID: Int)
    case set(stateID: Int)
}

/// Produces the only legal hardware transition: a previously asserted state
/// is released before another one is asserted. The Tiny retains state IDs, so
/// this prevents two semantic signals from overlapping on the physical LED.
public enum SOMALEDHardwareTransition {
    public static func commands(
        previousStateID: Int?,
        nextStateID: Int
    ) -> [SOMALEDHardwareCommand] {
        guard previousStateID != nextStateID else { return [] }
        if let previousStateID {
            return [.clear(stateID: previousStateID), .set(stateID: nextStateID)]
        }
        return [.set(stateID: nextStateID)]
    }
}

public struct SOMALEDSettings: Codable, Equatable, Sendable {
    public var responseMode: SOMALEDResponseMode
    /// OBSBOT exposes four discrete brightness levels, 0 through 3.
    public var brightness: Int
    /// Each meaningful interaction state has an independently selected colour
    /// and a physically supported device behavior.
    public var signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]

    public init(
        responseMode: SOMALEDResponseMode = .expressive,
        brightness: Int = 2,
        signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]? = nil
    ) {
        self.responseMode = responseMode
        self.brightness = min(max(brightness, 0), 3)
        self.signals = Self.normalized(signals ?? [:])
    }

    public func signal(for state: SubconsciousIndicatorState) -> SOMALEDSignalSettings {
        let canonical = state.configurationState
        if let signal = signals[canonical] {
            return signal
        }
        if canonical == .conversation {
            return signals[.speaking] ?? signals[.listening] ?? Self.defaultSignal(for: canonical)
        }
        return Self.defaultSignal(for: canonical)
    }

    private static func normalized(
        _ signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    ) -> [SubconsciousIndicatorState: SOMALEDSignalSettings] {
        Dictionary(uniqueKeysWithValues: SubconsciousIndicatorState.configurationStates.map { state in
            (state, signal(for: state, from: signals).normalizedForDevice())
        })
    }

    private static func signal(
        for state: SubconsciousIndicatorState,
        from signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    ) -> SOMALEDSignalSettings {
        if let signal = signals[state] { return signal }
        if state == .conversation {
            return signals[.speaking] ?? signals[.listening] ?? defaultSignal(for: state)
        }
        return defaultSignal(for: state)
    }

    private static func defaultSignal(
        for state: SubconsciousIndicatorState
    ) -> SOMALEDSignalSettings {
        switch state {
        case .exploring: .init(color: .yellow, pattern: .steady)
        case .humanDetected: .init(color: .blue, pattern: .steady)
        // State 18 is the physically verified continuous blue firmware blink.
        case .contactReady: .init(color: .blue, pattern: .blink)
        case .conversation, .listening, .speaking: .init(color: .blue, pattern: .steady)
        case .working: .init(color: .green, pattern: .steady)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case responseMode
        case brightness
        case signals
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        responseMode = try values.decodeIfPresent(SOMALEDResponseMode.self, forKey: .responseMode) ?? .expressive
        brightness = min(max(try values.decodeIfPresent(Int.self, forKey: .brightness) ?? 2, 0), 3)
        signals = Self.normalized(
            try values.decodeIfPresent([SubconsciousIndicatorState: SOMALEDSignalSettings].self, forKey: .signals) ?? [:]
        )
    }
}

/// Personal metadata deliberately kept apart from the encrypted face
/// embedding store. A face match identifies a local entity ID; only this
/// mapping grants that entity the local administrator label.
public struct SOMAAdministratorIdentity: Codable, Equatable, Sendable {
    public let entityID: UUID
    public var displayName: String
    public var preferredAddress: String?

    public init(entityID: UUID, displayName: String, preferredAddress: String? = nil) {
        self.entityID = entityID
        self.displayName = Self.clean(displayName, limit: 96, fallback: "Administrator")
        let cleanedAddress = preferredAddress.map { Self.clean($0, limit: 96, fallback: "") }
        self.preferredAddress = cleanedAddress?.isEmpty == true ? nil : cleanedAddress
    }

    private static func clean(_ value: String, limit: Int, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(limit))
    }
}

/// User-controlled settings consumed by the local runtime at process launch.
/// None of the fields contain face embeddings or other raw biometric material.
public struct SOMAControlSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var realtimeVoiceEnabled: Bool
    public var realtimeVoice: SOMARealtimeVoice
    public var led: SOMALEDSettings
    /// These settings only narrow the launch-agent capabilities; they can
    /// never grant motion authority that the service was not launched with.
    public var nativeHumanTrackingEnabled: Bool
    public var autonomousExplorationEnabled: Bool
    public var administrator: SOMAAdministratorIdentity?

    public init(
        schemaVersion: Int = SOMAControlSettings.currentSchemaVersion,
        realtimeVoiceEnabled: Bool = true,
        realtimeVoice: SOMARealtimeVoice = .maple,
        led: SOMALEDSettings = .init(),
        nativeHumanTrackingEnabled: Bool = true,
        autonomousExplorationEnabled: Bool = true,
        administrator: SOMAAdministratorIdentity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.realtimeVoiceEnabled = realtimeVoiceEnabled
        self.realtimeVoice = realtimeVoice
        self.led = led
        self.nativeHumanTrackingEnabled = nativeHumanTrackingEnabled
        self.autonomousExplorationEnabled = autonomousExplorationEnabled
        self.administrator = administrator
    }

    public var isCurrentSchema: Bool { schemaVersion == Self.currentSchemaVersion }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case realtimeVoiceEnabled
        case realtimeVoice
        case led
        case nativeHumanTrackingEnabled
        case autonomousExplorationEnabled
        case administrator
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(sourceVersion) else {
            throw SOMAControlSettingsStoreError.unsupportedSchema(sourceVersion)
        }
        schemaVersion = Self.currentSchemaVersion
        realtimeVoiceEnabled = try values.decodeIfPresent(Bool.self, forKey: .realtimeVoiceEnabled) ?? true
        realtimeVoice = try values.decodeIfPresent(SOMARealtimeVoice.self, forKey: .realtimeVoice) ?? .maple
        var decodedLED = try values.decodeIfPresent(SOMALEDSettings.self, forKey: .led) ?? .init()
        // Schema 2 used a host-generated double pulse for Ready to talk. The
        // connected device accepts those phase commands without visibly
        // blinking, so migrate the shipped default to its native blue blink.
        if sourceVersion < 3,
           decodedLED.signal(for: .contactReady).color == .blue {
            decodedLED.signals[.contactReady] = .init(color: .blue, pattern: .blink)
        }
        led = decodedLED
        nativeHumanTrackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .nativeHumanTrackingEnabled) ?? true
        autonomousExplorationEnabled = try values.decodeIfPresent(Bool.self, forKey: .autonomousExplorationEnabled) ?? true
        administrator = try values.decodeIfPresent(SOMAAdministratorIdentity.self, forKey: .administrator)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(realtimeVoiceEnabled, forKey: .realtimeVoiceEnabled)
        try values.encode(realtimeVoice, forKey: .realtimeVoice)
        try values.encode(led, forKey: .led)
        try values.encode(nativeHumanTrackingEnabled, forKey: .nativeHumanTrackingEnabled)
        try values.encode(autonomousExplorationEnabled, forKey: .autonomousExplorationEnabled)
        try values.encodeIfPresent(administrator, forKey: .administrator)
    }
}

public enum SOMAControlSettingsStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case corruptSettings
    case insecurePermissions

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported SOMA settings schema: \(version)"
        case .corruptSettings:
            "SOMA settings could not be decoded"
        case .insecurePermissions:
            "SOMA settings permissions must be owner-only"
        }
    }
}

public struct SOMAControlSettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultURL()) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/settings.json")
    }

    public func load() throws -> SOMAControlSettings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .init() }
        try requireOwnerOnlyPermissions()
        do {
            let settings = try JSONDecoder().decode(
                SOMAControlSettings.self,
                from: Data(contentsOf: fileURL, options: .mappedIfSafe)
            )
            guard settings.isCurrentSchema else {
                throw SOMAControlSettingsStoreError.unsupportedSchema(settings.schemaVersion)
            }
            return settings
        } catch let error as SOMAControlSettingsStoreError {
            throw error
        } catch {
            throw SOMAControlSettingsStoreError.corruptSettings
        }
    }

    public func save(_ settings: SOMAControlSettings) throws {
        guard settings.isCurrentSchema else {
            throw SOMAControlSettingsStoreError.unsupportedSchema(settings.schemaVersion)
        }
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func requireOwnerOnlyPermissions() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw SOMAControlSettingsStoreError.insecurePermissions
        }
    }
}
