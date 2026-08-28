import XCTest
@testable import SOMACore

final class OBSBOTDeviceProfileTests: XCTestCase {
    func testTiny2LiteCommandsComeFromTheNativeContract() {
        let contract = tiny2LiteTestContract()
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .green), 57)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .blue), 54)
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .blue))
        XCTAssertEqual(contract.nativeTrackingTransport, .legacyHumanMode)
    }

    func testTiny3LiteUsesOnlyItsVerifiedIndicatorRoutes() {
        let contract = tiny3LiteTestContract()
        let capabilities = contract.capabilities

        XCTAssertFalse(capabilities.supportsCalibratedMotorControl)
        XCTAssertTrue(capabilities.supportsBoundedCalibrationPulses)
        XCTAssertTrue(capabilities.supportsFirmwareIndicatorPalette)
        XCTAssertFalse(capabilities.supportsDirectIndicatorRGB)
        XCTAssertTrue(capabilities.supportsIndicatorEnableAndBrightness)
        XCTAssertTrue(capabilities.supportsSelectableAudioModes)
        XCTAssertTrue(capabilities.supportsDeviceSoundLocalization)
        XCTAssertTrue(capabilities.requiresMeasuredAttitudeFrame)
        XCTAssertEqual(capabilities.maximumPanDegreesPerSecond, 90)
        XCTAssertEqual(capabilities.maximumPitchDegreesPerSecond, 45)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .green), 54)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .blue), 57)
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .green))
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .yellow))
        XCTAssertEqual(contract.nativeTrackingTransport, .selectedHumanPortrait)
    }

    func testTiny3LiteFOVUsesItsOwnWideOpticsProfile() {
        XCTAssertEqual(
            OBSBOTDeviceProfile.tiny3Lite.horizontalFieldOfViewDegrees(forSDKMode: 86) ?? 0,
            72,
            accuracy: 0.001
        )
        XCTAssertNotEqual(
            OBSBOTDeviceProfile.tiny3Lite.horizontalFieldOfViewDegrees(forSDKMode: 78),
            OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 78)
        )
        XCTAssertNil(OBSBOTDeviceProfile.tiny3Lite.horizontalFieldOfViewDegrees(forSDKMode: 70))
    }

    func testTiny3LiteMapsOnlyRetainedMicrophoneModesToFirmware() {
        let contract = tiny3LiteTestContract()
        XCTAssertEqual(contract.firmwareAudioMode(for: .ambientOmni), 0)
        XCTAssertEqual(contract.firmwareAudioMode(for: .spatialStereo), 1)
        XCTAssertEqual(contract.firmwareAudioMode(for: .conversationFront), 2)
        XCTAssertNil(contract.firmwareAudioMode(for: .rear))
        XCTAssertEqual(contract.firmwareAudioMode(for: .bidirectional), 4)
        XCTAssertEqual(contract.firmwareAudioMode(for: .music), 5)
        XCTAssertNil(tiny2LiteTestContract().firmwareAudioMode(for: .spatialStereo))
    }

    func testTiny3CalibrationRequiresMeasuredPoseProjectionForMotionAuthority() {
        let measured = ExternalGimbalCalibration.fromPositivePulseDisplacements(
            panImageDelta: -0.06,
            pitchImageDelta: 0.04,
            deviceProfile: .tiny3Lite,
            panPoseDelta: -3.0,
            pitchPoseDelta: 2.0,
            homePose: GimbalPose(pitchDegrees: 0.5, panDegrees: -0.1, monotonicNS: 1)
        )
        XCTAssertTrue(measured?.isValid ?? false)
        XCTAssertTrue(measured?.hasMeasuredPoseProjection ?? false)
        XCTAssertTrue(measured?.hasMeasuredAttitudeFrame ?? false)
        XCTAssertEqual(measured?.poseProjection.panImageSign, 1)
        XCTAssertEqual(measured?.poseProjection.pitchImageSign, 1)
        XCTAssertEqual(measured?.pitchCommand(forPoseError: -12, projection: .identity), -12)
        XCTAssertEqual(measured?.panCommand(forPoseError: 12, projection: .identity), -12)

        XCTAssertNil(ExternalGimbalCalibration.fromPositivePulseDisplacements(
            panImageDelta: -0.06,
            pitchImageDelta: 0.04,
            deviceProfile: .tiny3Lite,
            panPoseDelta: -3.0
        ))
    }
}
