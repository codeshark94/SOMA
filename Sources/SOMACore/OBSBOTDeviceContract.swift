import Foundation

public enum OBSBOTIndicatorPulseTransport: Int, Sendable {
    case unavailable = 0
    case brightnessDimming = 1
    case enableToggle = 2
    case directDark = 3
}

/// Runtime hardware contract emitted by the native OBSBOT adapter.
///
/// Product-specific SDK transport stays inside the native adapter.  Swift
/// receives this narrow, versioned contract and enables only the operations
/// the connected device explicitly declares.
public struct OBSBOTDeviceContract: Equatable, Sendable {
    public static let schemaVersion = 2

    public let profileID: String
    public let productType: Int?
    public let firmware: String?
    public let serial: String?
    public let supportsNativeBridge: Bool
    public let supportsNativeHumanTracking: Bool
    public let capabilities: OBSBOTDeviceCapabilities
    public let indicatorStateIDs: [SOMALEDColor: Int]
    public let directIndicatorColors: Set<SOMALEDColor>
    public let firmwareDefaultIndicatorColors: Set<SOMALEDColor>
    public let indicatorPulseTransport: OBSBOTIndicatorPulseTransport
    public let supportedFirmwareAudioModes: Set<UInt8>
    public let nativeTrackingTransport: OBSBOTNativeTrackingTransport

    public var knownProfile: OBSBOTDeviceProfile? {
        OBSBOTDeviceProfile(rawValue: profileID)
    }

    public init(
        profileID: String,
        productType: Int? = nil,
        firmware: String? = nil,
        serial: String? = nil,
        supportsNativeBridge: Bool,
        supportsNativeHumanTracking: Bool,
        capabilities: OBSBOTDeviceCapabilities,
        indicatorStateIDs: [SOMALEDColor: Int] = [:],
        directIndicatorColors: Set<SOMALEDColor> = [],
        firmwareDefaultIndicatorColors: Set<SOMALEDColor> = [],
        indicatorPulseTransport: OBSBOTIndicatorPulseTransport = .unavailable,
        supportedFirmwareAudioModes: Set<UInt8> = [],
        nativeTrackingTransport: OBSBOTNativeTrackingTransport = .unavailable
    ) {
        self.profileID = profileID
        self.productType = productType
        self.firmware = firmware
        self.serial = serial
        self.supportsNativeBridge = supportsNativeBridge
        self.supportsNativeHumanTracking = supportsNativeHumanTracking
        self.capabilities = capabilities
        self.indicatorStateIDs = indicatorStateIDs
        self.directIndicatorColors = directIndicatorColors
        self.firmwareDefaultIndicatorColors = firmwareDefaultIndicatorColors
        self.indicatorPulseTransport = indicatorPulseTransport
        self.supportedFirmwareAudioModes = supportedFirmwareAudioModes
        self.nativeTrackingTransport = nativeTrackingTransport
    }

    /// Parses the single-line protocol emitted by both `soma-obsbot-probe`
    /// and `soma-native-track`. Values are deliberately space-free, so the
    /// contract remains safe to carry through an environment variable.
    public static func parse(_ line: String) -> OBSBOTDeviceContract? {
        let prefix = "SOMA_OBSBOT_CAPABILITY "
        let payload = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
        let fields = payload.split(separator: " ").reduce(into: [String: String]()) { values, token in
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return }
            values[String(pair[0])] = String(pair[1])
        }
        guard fields["contract"] == String(schemaVersion),
              let profileID = fields["profile"],
              let supportsNativeBridge = bool(fields["native_bridge"]),
              let supportsNativeHumanTracking = bool(fields["native_human_tracking"]),
              let motorCalibrated = bool(fields["motor_calibrated"]),
              let boundedCalibrationPulses = bool(fields["bounded_calibration_pulses"]),
              let indicatorPalette = bool(fields["indicator_palette"]),
              let defaultGreen = bool(fields["indicator_default_green"]),
              let directRGB = bool(fields["indicator_direct_rgb"]),
              let directRGBMask = integer(fields["indicator_direct_rgb_mask"], in: 0...7),
              let indicatorBasic = bool(fields["indicator_basic"]),
              let selectableAudioModes = bool(fields["selectable_audio_modes"]),
              let supportedAudioModeMask = integer(fields["supported_audio_mode_mask"], in: 0...255),
              let soundLocalization = bool(fields["sound_localization"]),
              let measuredAttitude = bool(fields["requires_measured_attitude_frame"]),
              let nativeTrackingTransportRaw = integer(fields["native_tracking_transport"], in: 0...2),
              let nativeTrackingTransport = OBSBOTNativeTrackingTransport(rawValue: nativeTrackingTransportRaw),
              let yellowIndicatorStateID = indicatorStateID(fields["indicator_yellow_state_id"]),
              let greenIndicatorStateID = indicatorStateID(fields["indicator_green_state_id"]),
              let blueIndicatorStateID = indicatorStateID(fields["indicator_blue_state_id"]),
              let maximumPan = finiteNonnegative(fields["maximum_pan_degrees_per_second"]),
              let maximumPitch = finiteNonnegative(fields["maximum_pitch_degrees_per_second"]),
              let wideFOV = finiteNonnegative(fields["nominal_wide_horizontal_fov_degrees"])
        else {
            return nil
        }
        guard !supportsNativeBridge || (maximumPan > 0 && maximumPitch > 0 && wideFOV > 0) else {
            return nil
        }
        let indicatorPulseTransport: OBSBOTIndicatorPulseTransport
        if let rawValue = fields["indicator_pulse_transport"] {
            guard let raw = integer(rawValue, in: 0...3),
                  let parsed = OBSBOTIndicatorPulseTransport(rawValue: raw)
            else { return nil }
            indicatorPulseTransport = parsed
        } else {
            indicatorPulseTransport = .unavailable
        }
        switch indicatorPulseTransport {
        case .brightnessDimming, .enableToggle:
            guard indicatorBasic else { return nil }
        case .directDark:
            guard directRGB else { return nil }
        case .unavailable:
            break
        }
        var indicatorStateIDs: [SOMALEDColor: Int] = [:]
        if yellowIndicatorStateID >= 0 { indicatorStateIDs[.yellow] = yellowIndicatorStateID }
        if greenIndicatorStateID >= 0 { indicatorStateIDs[.green] = greenIndicatorStateID }
        if blueIndicatorStateID >= 0 { indicatorStateIDs[.blue] = blueIndicatorStateID }
        let directIndicatorColors = Set(SOMALEDColor.allCases.enumerated().compactMap { index, color in
            directRGBMask & (1 << index) != 0 ? color : nil
        })
        guard directRGB == !directIndicatorColors.isEmpty else { return nil }
        guard !indicatorPalette || !indicatorStateIDs.isEmpty || directRGB else {
            return nil
        }
        guard !defaultGreen || indicatorPalette || directRGB else { return nil }
        let firmwareDefaultIndicatorColors: Set<SOMALEDColor> = defaultGreen ? [.green] : []
        let supportedFirmwareAudioModes = Set((0..<8).compactMap { mode -> UInt8? in
            supportedAudioModeMask & (1 << mode) != 0 ? UInt8(mode) : nil
        })
        guard selectableAudioModes == !supportedFirmwareAudioModes.isEmpty else { return nil }

        return OBSBOTDeviceContract(
            profileID: profileID,
            productType: fields["product_type"].flatMap(Int.init),
            firmware: fields["firmware"],
            serial: fields["serial"],
            supportsNativeBridge: supportsNativeBridge,
            supportsNativeHumanTracking: supportsNativeHumanTracking,
            capabilities: OBSBOTDeviceCapabilities(
                supportsCalibratedMotorControl: motorCalibrated,
                supportsBoundedCalibrationPulses: boundedCalibrationPulses,
                supportsFirmwareIndicatorPalette: indicatorPalette,
                supportsDirectIndicatorRGB: directRGB,
                supportsIndicatorEnableAndBrightness: indicatorBasic,
                supportsSelectableAudioModes: selectableAudioModes,
                supportsDeviceSoundLocalization: soundLocalization,
                requiresMeasuredAttitudeFrame: measuredAttitude,
                maximumPanDegreesPerSecond: maximumPan,
                maximumPitchDegreesPerSecond: maximumPitch,
                nominalWideHorizontalFieldOfViewDegrees: wideFOV
            ),
            indicatorStateIDs: indicatorStateIDs,
            directIndicatorColors: directIndicatorColors,
            firmwareDefaultIndicatorColors: firmwareDefaultIndicatorColors,
            indicatorPulseTransport: indicatorPulseTransport,
            supportedFirmwareAudioModes: supportedFirmwareAudioModes,
            nativeTrackingTransport: nativeTrackingTransport
        )
    }

    public func firmwareIndicatorStateID(for color: SOMALEDColor) -> Int? {
        indicatorStateIDs[color]
    }

    public func supportsDirectIndicatorColor(_ color: SOMALEDColor) -> Bool {
        directIndicatorColors.contains(color)
    }

    public func usesFirmwareDefaultIndicator(for color: SOMALEDColor) -> Bool {
        firmwareDefaultIndicatorColors.contains(color)
    }

    public func firmwareAudioMode(for captureMode: MicrophoneCaptureMode) -> UInt8? {
        let mode: UInt8 = switch captureMode {
        case .ambientOmni: 0
        case .spatialStereo: 1
        case .conversationFront: 2
        case .rear: 3
        case .bidirectional: 4
        case .music: 5
        }
        return supportedFirmwareAudioModes.contains(mode) ? mode : nil
    }

    public func indicatorPattern(for pattern: SOMALEDPattern) -> SOMALEDPattern {
        nativeTrackingTransport == .selectedHumanPortrait && pattern == .firmwareAnimation
            ? .blink
            : pattern
    }

    private static func bool(_ value: String?) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func finiteNonnegative(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func indicatorStateID(_ value: String?) -> Int? {
        guard let value, let stateID = Int(value), (-1...255).contains(stateID) else { return nil }
        return stateID
    }

    private static func integer(_ value: String?, in range: ClosedRange<Int>) -> Int? {
        guard let value, let integer = Int(value), range.contains(integer) else { return nil }
        return integer
    }
}

public enum OBSBOTNativeTrackingTransport: Int, Equatable, Sendable {
    case unavailable = 0
    case legacyHumanMode = 1
    case selectedHumanPortrait = 2
}
