import Foundation

/// Stable identity for the OBSBOT hardware profiles SOMA can use. The native
/// helper reports this value from exact USB identity; it is never inferred
/// from a display name or a USB channel count.
public enum OBSBOTDeviceProfile: String, Codable, CaseIterable, Sendable {
    case tiny2Lite = "tiny_2_lite"
    case tiny3Lite = "tiny_3_lite"

    public var kinematicEnvelope: GimbalKinematicEnvelope {
        switch self {
        case .tiny2Lite: .obsbotTiny2Lite
        case .tiny3Lite: .obsbotTiny3Lite
        }
    }

    /// Firmware FOV values are nominal diagonal crop modes. Convert them through
    /// the profile's physical wide-angle specification before spatial mapping.
    public func horizontalFieldOfViewDegrees(forNominalMode mode: Double) -> Double? {
        let nominalWideHorizontalFieldOfViewDegrees = switch self {
        case .tiny2Lite: 67.2
        case .tiny3Lite: 72.0
        }
        return OBSBOTDeviceCapabilities.horizontalFieldOfViewDegrees(
            nominalWide: nominalWideHorizontalFieldOfViewDegrees,
            forNominalMode: mode
        )
    }
}

public struct OBSBOTDeviceCapabilities: Codable, Equatable, Sendable {
    public let supportsCalibratedMotorControl: Bool
    public let supportsBoundedCalibrationPulses: Bool
    public let supportsFirmwareIndicatorPalette: Bool
    public let supportsDirectIndicatorRGB: Bool
    public let supportsIndicatorEnableAndBrightness: Bool
    public let supportsSelectableAudioModes: Bool
    /// The open bridge can enable firmware sound-source tracking. The device
    /// does not expose a raw source-bearing callback through this interface.
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

    public func horizontalFieldOfViewDegrees(forNominalMode mode: Double) -> Double? {
        Self.horizontalFieldOfViewDegrees(
            nominalWide: nominalWideHorizontalFieldOfViewDegrees,
            forNominalMode: mode
        )
    }

    static func horizontalFieldOfViewDegrees(
        nominalWide: Double,
        forNominalMode mode: Double
    ) -> Double? {
        guard [65.0, 78.0, 86.0].contains(mode),
              nominalWide.isFinite,
              nominalWide > 0 else {
            return nil
        }
        let cropRatio = tan(mode * .pi / 360) / tan(86.0 * .pi / 360)
        return atan(
            tan(nominalWide * .pi / 360) * cropRatio
        ) * 360 / .pi
    }
}
