import XCTest
@testable import SOMACore

final class OBSBOTDeviceProfileTests: XCTestCase {
    func testTiny2LiteKeepsTheCompleteSemanticIndicatorPalette() {
        XCTAssertEqual(OBSBOTDeviceProfile.tiny2Lite.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny2Lite.firmwareIndicatorStateID(for: .green), 57)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny2Lite.firmwareIndicatorStateID(for: .blue), 54)
        XCTAssertNil(OBSBOTDeviceProfile.tiny2Lite.directIndicatorRGB(for: .blue))
    }

    func testTiny3LiteUsesItsOwnMotorAndIndicatorCapabilities() {
        let capabilities = OBSBOTDeviceProfile.tiny3Lite.capabilities

        XCTAssertFalse(capabilities.supportsCalibratedMotorControl)
        XCTAssertTrue(capabilities.supportsBoundedCalibrationPulses)
        XCTAssertFalse(capabilities.supportsFirmwareIndicatorPalette)
        XCTAssertTrue(capabilities.supportsDirectIndicatorRGB)
        XCTAssertTrue(capabilities.supportsIndicatorEnableAndBrightness)
        XCTAssertTrue(capabilities.supportsSelectableAudioModes)
        XCTAssertTrue(capabilities.supportsDeviceSoundLocalization)
        XCTAssertTrue(capabilities.requiresMeasuredAttitudeFrame)
        XCTAssertEqual(capabilities.maximumPanDegreesPerSecond, 90)
        XCTAssertEqual(capabilities.maximumPitchDegreesPerSecond, 45)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.supportedFirmwareIndicatorStateIDs, [])
        XCTAssertFalse(OBSBOTDeviceProfile.tiny3Lite.supportsFirmwareIndicatorStateID(57))
        XCTAssertFalse(OBSBOTDeviceProfile.tiny3Lite.supportsFirmwareIndicatorStateID(18))
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

    func testTiny3LiteMapsEverySemanticMicrophoneModeToFirmware() {
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.firmwareAudioMode(for: .ambientOmni), 0)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.firmwareAudioMode(for: .spatialStereo), 1)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.firmwareAudioMode(for: .conversationFront), 2)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.firmwareAudioMode(for: .rear), 3)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.firmwareAudioMode(for: .bidirectional), 4)
        XCTAssertEqual(OBSBOTDeviceProfile.tiny3Lite.firmwareAudioMode(for: .music), 5)
        XCTAssertNil(OBSBOTDeviceProfile.tiny2Lite.firmwareAudioMode(for: .spatialStereo))
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
