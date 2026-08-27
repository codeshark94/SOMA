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

/// A user-facing colour available from the connected OBSBOT indicator. There
/// is no public RGB API, so each entry maps to a firmware palette state.
public enum SOMALEDColor: String, CaseIterable, Codable, Sendable {
    case yellow
    case green
    case blue

    public var displayName: String {
        switch self {
        case .yellow, .green, .blue:
            rawValue.capitalized
        }
    }

    /// The setting surface stays semantic. The connected product profile
    /// resolves each colour to its own firmware palette entry at runtime.
    public static let selectableCases: [Self] = allCases

}

public struct SOMALEDDirectRGB: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The Tiny 3 indicator transport accepts semantic RGB values directly.
    /// Keep the supported palette deliberately small: cognition selects a
    /// social state, never an arbitrary decorative colour.
    public static let green = Self(red: 0, green: 255, blue: 0)
    public static let yellow = Self(red: 255, green: 210, blue: 0)
    public static let blue = Self(red: 0, green: 0, blue: 255)
}

/// A device-specific status-indicator rendering. Palette state IDs and
/// direct RGB requests are separate transports and must never be mixed.
public struct SOMALEDDeviceRendering: Equatable, Sendable {
    public let stateID: Int?
    public let directRGB: SOMALEDDirectRGB?
    public let pattern: SOMALEDPattern

    public init(stateID: Int, pattern: SOMALEDPattern) {
        self.stateID = stateID
        directRGB = nil
        self.pattern = pattern
    }

    public init(directRGB: SOMALEDDirectRGB, pattern: SOMALEDPattern) {
        stateID = nil
        self.directRGB = directRGB
        self.pattern = pattern
    }

    public var usesDirectRGB: Bool { directRGB != nil }
    public var pulseEnabled: Bool { pattern != .steady }
}

/// Internal calibration entries for Tiny devices. These describe the
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
        case .targetLock, .gesture: "Green"
        case .normalWork: "Blue"
        case .tracking: "Green"
        }
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
    case firmwareAnimation = "firmware_animation"
    case beacon
    case doubleBlink
    case longPulse
    case heartbeat
    case blink

    public var displayName: String {
        switch self {
        case .steady: "Steady"
        case .firmwareAnimation: "Contact pulse"
        case .beacon: "Beacon"
        case .doubleBlink: "Double blink"
        case .longPulse: "Long pulse"
        case .heartbeat: "Heartbeat"
        case .blink: "Blink"
        }
    }

    public func isPhysicallySupported(for color: SOMALEDColor) -> Bool {
        // Timing is host-controlled; any firmware palette position can carry
        // the same temporal pattern even before its colour is visually named.
        true
    }

    public var indicatorPattern: SubconsciousIndicatorPattern {
        switch self {
        case .steady:
            .init(name: "steady", phases: [
                .init(illuminated: true, durationMilliseconds: nil),
            ])
        case .firmwareAnimation:
            .init(name: "firmware_animation", phases: [
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

    public func deviceRendering(for profile: OBSBOTDeviceProfile) -> SOMALEDDeviceRendering? {
        if let directRGB = profile.directIndicatorRGB(for: color) {
            return .init(directRGB: directRGB, pattern: pattern)
        }
        guard let stateID = profile.firmwareIndicatorStateID(for: color) else { return nil }
        return .init(stateID: stateID, pattern: pattern)
    }

    public func normalizedForDevice() -> Self {
        guard pattern.isPhysicallySupported(for: color) else {
            return .init(color: color, pattern: .steady)
        }
        return self
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
        case .targetLock, .gesture, .normalWork, .tracking:
            color = .green
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(color, forKey: .color)
        try values.encode(pattern, forKey: .pattern)
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

    /// The indicator cadence denotes the visual interaction state. A voice
    /// session changes the state to conversation, but must not manufacture an
    /// eye-contact blink after visual contact has ended.
    public func deviceRendering(
        for state: SubconsciousIndicatorState,
        on profile: OBSBOTDeviceProfile
    ) -> SOMALEDDeviceRendering? {
        signal(for: state).deviceRendering(for: profile)
    }

    private static func normalized(
        _ signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    ) -> [SubconsciousIndicatorState: SOMALEDSignalSettings] {
        Dictionary(uniqueKeysWithValues: SubconsciousIndicatorState.configurationStates.map { state in
            let selected = signal(for: state, from: signals)
            return (state, selected.normalizedForDevice())
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
        case .exploring: .init(color: .green, pattern: .steady)
        case .humanDetected: .init(color: .blue, pattern: .steady)
        case .contactReady: .init(color: .blue, pattern: .firmwareAnimation)
        case .conversation, .listening, .speaking: .init(color: .yellow, pattern: .steady)
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
    public static let currentSchemaVersion = 8

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
        if sourceVersion < 6,
           decodedLED.signal(for: .contactReady).pattern == .steady {
            let contactSignal = decodedLED.signal(for: .contactReady)
            decodedLED.signals[.contactReady] = .init(
                color: contactSignal.color,
                pattern: .blink
            )
        }
        if sourceVersion < 7 {
            // These are social meanings, not a device fallback palette:
            // visible person = blue, direct mutual attention = blue blink,
            // and an active spoken session = green.
            decodedLED.signals[.exploring] = .init(color: .yellow, pattern: .steady)
            decodedLED.signals[.humanDetected] = .init(color: .blue, pattern: .steady)
            decodedLED.signals[.contactReady] = .init(color: .blue, pattern: .blink)
            decodedLED.signals[.conversation] = .init(color: .green, pattern: .steady)
        }
        // A persisted signal is an operator-owned interaction contract. Older
        // schema versions may legitimately contain the explicit blue blink
        // used for direct contact, so decoding must never replace it with a
        // later default cadence.
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
