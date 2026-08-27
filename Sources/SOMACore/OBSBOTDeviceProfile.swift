import Foundation

/// Stable identity for the OBSBOT hardware profiles SOMA can use. The native
/// helper reports this value from the SDK product type; it is never inferred
/// from a display name or a USB channel count.
public enum OBSBOTDeviceProfile: String, Codable, CaseIterable, Sendable {
    case tiny2Lite = "tiny_2_lite"
    case tiny3Lite = "tiny_3_lite"

    public var capabilities: OBSBOTDeviceCapabilities {
        switch self {
        case .tiny2Lite:
            return .init(
                supportsCalibratedMotorControl: true,
                supportsBoundedCalibrationPulses: false,
                supportsFirmwareIndicatorPalette: true,
                supportsDirectIndicatorRGB: false,
                supportsIndicatorEnableAndBrightness: true,
                supportsSelectableAudioModes: false,
                supportsDeviceSoundLocalization: false,
                requiresMeasuredAttitudeFrame: false,
                maximumPanDegreesPerSecond: 180,
                maximumPitchDegreesPerSecond: 90,
                nominalWideHorizontalFieldOfViewDegrees: 67.2
            )
        case .tiny3Lite:
            return .init(
                supportsCalibratedMotorControl: false,
                supportsBoundedCalibrationPulses: true,
                supportsFirmwareIndicatorPalette: false,
                supportsDirectIndicatorRGB: true,
                supportsIndicatorEnableAndBrightness: true,
                supportsSelectableAudioModes: true,
                supportsDeviceSoundLocalization: true,
                requiresMeasuredAttitudeFrame: true,
                maximumPanDegreesPerSecond: 90,
                maximumPitchDegreesPerSecond: 45,
                nominalWideHorizontalFieldOfViewDegrees: 72
            )
        }
    }

    /// Status states accepted by the product firmware's indicator controller.
    /// They are opaque firmware-owned palette entries, not programmable RGB
    /// values. Keeping this table at the device boundary prevents cognitive
    /// callers from emitting arbitrary state IDs.
    public var supportedFirmwareIndicatorStateIDs: Set<Int> {
        switch self {
        case .tiny2Lite:
            [16, 17, 18, 54, 57]
        case .tiny3Lite:
            []
        }
    }

    public func supportsFirmwareIndicatorStateID(_ stateID: Int) -> Bool {
        supportedFirmwareIndicatorStateIDs.contains(stateID)
    }

    /// Resolves a semantic indicator colour at the hardware boundary. Firmware
    /// state IDs are product-specific palette entries, not colour constants.
    public func firmwareIndicatorStateID(for color: SOMALEDColor) -> Int? {
        switch self {
        case .tiny2Lite:
            switch color {
            case .yellow: 16
            case .green: 57
            // The Tiny 2's normal-work palette is the firmware blue state.
            // It keeps human presence and eye-contact semantics available
            // when switching between the Tiny 2 palette and Tiny 3 RGB path.
            case .blue: 54
            }
        case .tiny3Lite:
            nil
        }
    }

    /// Tiny 3 Lite's public state-ID endpoint belongs to another OBSBOT
    /// product family. Its segmented status light instead accepts SOMA's
    /// small semantic RGB palette through the device's RGB transport.
    public func directIndicatorRGB(for color: SOMALEDColor) -> SOMALEDDirectRGB? {
        guard self == .tiny3Lite else { return nil }
        return switch color {
        case .yellow: SOMALEDDirectRGB.yellow
        case .green: SOMALEDDirectRGB.green
        case .blue: SOMALEDDirectRGB.blue
        }
    }

    public var kinematicEnvelope: GimbalKinematicEnvelope {
        switch self {
        case .tiny2Lite: .obsbotTiny2Lite
        case .tiny3Lite: .obsbotTiny3Lite
        }
    }

    /// SDK FOV values are nominal diagonal crop modes. Convert them through
    /// the profile's physical wide-angle specification before spatial mapping.
    public func horizontalFieldOfViewDegrees(forSDKMode mode: Double) -> Double? {
        guard [65.0, 78.0, 86.0].contains(mode) else { return nil }
        let nominalWideMode = 86.0
        let cropRatio = tan(mode * .pi / 360) / tan(nominalWideMode * .pi / 360)
        return atan(
            tan(capabilities.nominalWideHorizontalFieldOfViewDegrees * .pi / 360) * cropRatio
        ) * 360 / .pi
    }

    /// Returns the firmware mode after the active product profile has been
    /// checked.  Tiny 3 Lite provides these modes through its public binary
    /// ABI even though the distributed header omits the setter declaration.
    public func firmwareAudioMode(for captureMode: MicrophoneCaptureMode) -> UInt8? {
        guard self == .tiny3Lite else { return nil }
        return switch captureMode {
        case .ambientOmni: 0
        case .spatialStereo: 1
        case .conversationFront: 2
        case .rear: 3
        case .bidirectional: 4
        case .music: 5
        }
    }
}

public struct OBSBOTDeviceCapabilities: Codable, Equatable, Sendable {
    public let supportsCalibratedMotorControl: Bool
    public let supportsBoundedCalibrationPulses: Bool
    public let supportsFirmwareIndicatorPalette: Bool
    public let supportsDirectIndicatorRGB: Bool
    public let supportsIndicatorEnableAndBrightness: Bool
    public let supportsSelectableAudioModes: Bool
    /// The SDK can enable firmware sound-source tracking. It does not expose
    /// a raw source-bearing callback through the public host interface.
    public let supportsDeviceSoundLocalization: Bool
    public let requiresMeasuredAttitudeFrame: Bool
    public let maximumPanDegreesPerSecond: Double
    public let maximumPitchDegreesPerSecond: Double
    public let nominalWideHorizontalFieldOfViewDegrees: Double

    public init(
        supportsCalibratedMotorControl: Bool,
        supportsBoundedCalibrationPulses: Bool,
        supportsFirmwareIndicatorPalette: Bool,
        supportsDirectIndicatorRGB: Bool,
        supportsIndicatorEnableAndBrightness: Bool,
        supportsSelectableAudioModes: Bool,
        supportsDeviceSoundLocalization: Bool,
        requiresMeasuredAttitudeFrame: Bool,
        maximumPanDegreesPerSecond: Double,
        maximumPitchDegreesPerSecond: Double,
        nominalWideHorizontalFieldOfViewDegrees: Double
    ) {
        self.supportsCalibratedMotorControl = supportsCalibratedMotorControl
        self.supportsBoundedCalibrationPulses = supportsBoundedCalibrationPulses
        self.supportsFirmwareIndicatorPalette = supportsFirmwareIndicatorPalette
        self.supportsDirectIndicatorRGB = supportsDirectIndicatorRGB
        self.supportsIndicatorEnableAndBrightness = supportsIndicatorEnableAndBrightness
        self.supportsSelectableAudioModes = supportsSelectableAudioModes
        self.supportsDeviceSoundLocalization = supportsDeviceSoundLocalization
        self.requiresMeasuredAttitudeFrame = requiresMeasuredAttitudeFrame
        self.maximumPanDegreesPerSecond = maximumPanDegreesPerSecond
        self.maximumPitchDegreesPerSecond = maximumPitchDegreesPerSecond
        self.nominalWideHorizontalFieldOfViewDegrees = nominalWideHorizontalFieldOfViewDegrees
    }
}
