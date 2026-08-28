import XCTest
@testable import SOMACore

final class OBSBOTDeviceContractTests: XCTestCase {
    func testNativeAdapterContractParsesWithoutDuplicatingStaticProfileCapabilities() {
        let contract = tiny3LiteTestContract()

        XCTAssertEqual(contract.knownProfile, .tiny3Lite)
        XCTAssertEqual(contract.firmware, "6.5.10.1")
        XCTAssertTrue(contract.supportsNativeBridge)
        XCTAssertTrue(contract.supportsNativeHumanTracking)
        XCTAssertTrue(contract.capabilities.requiresMeasuredAttitudeFrame)
        XCTAssertEqual(contract.capabilities.nominalWideHorizontalFieldOfViewDegrees, 72)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .green), 54)
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .green))
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .blue), 57)
        XCTAssertEqual(
            SOMALEDSignalSettings(color: .yellow, pattern: .steady)
                .deviceRendering(for: contract),
            .init(stateID: 16, pattern: .steady)
        )
    }

    func testTiny3SemanticIndicatorStatesUseOnlyAdapterDeclaredRoutes() {
        let contract = tiny3LiteTestContract()
        let settings = SOMALEDSettings()

        XCTAssertEqual(settings.deviceRendering(for: .exploring, on: contract), .init(stateID: 54, pattern: .steady))
        XCTAssertEqual(settings.deviceRendering(for: .humanDetected, on: contract), .init(stateID: 57, pattern: .steady))
        XCTAssertEqual(settings.deviceRendering(for: .contactReady, on: contract), .init(stateID: 57, pattern: .blink))
        XCTAssertEqual(settings.deviceRendering(for: .conversation, on: contract), .init(stateID: 16, pattern: .steady))
    }

    func testTiny3RejectsFirmwareAudioModeThatDidNotPersistOnHardware() {
        let contract = tiny3LiteTestContract()

        XCTAssertEqual(contract.firmwareAudioMode(for: .ambientOmni), 0)
        XCTAssertEqual(contract.firmwareAudioMode(for: .spatialStereo), 1)
        XCTAssertEqual(contract.firmwareAudioMode(for: .conversationFront), 2)
        XCTAssertNil(contract.firmwareAudioMode(for: .rear))
        XCTAssertEqual(contract.firmwareAudioMode(for: .bidirectional), 4)
        XCTAssertEqual(contract.firmwareAudioMode(for: .music), 5)
    }

    func testUnknownDeviceContractRemainsPerceptionOnly() {
        let line = "SOMA_OBSBOT_CAPABILITY contract=2 profile=unknown product_type=44 native_bridge=false motor_calibrated=false bounded_calibration_pulses=false native_human_tracking=false indicator_palette=false indicator_default_green=false indicator_direct_rgb=false indicator_direct_rgb_mask=0 indicator_basic=false selectable_audio_modes=false supported_audio_mode_mask=0 sound_localization=false requires_measured_attitude_frame=false native_tracking_transport=0 indicator_yellow_state_id=-1 indicator_green_state_id=-1 indicator_blue_state_id=-1 maximum_pan_degrees_per_second=0 maximum_pitch_degrees_per_second=0 nominal_wide_horizontal_fov_degrees=0 firmware=1.0 serial=XYZ"

        let contract = OBSBOTDeviceContract.parse(line)

        XCTAssertNil(contract?.knownProfile)
        XCTAssertFalse(contract?.supportsNativeBridge ?? true)
        XCTAssertEqual(contract?.profileID, "unknown")
    }

    func testFirmwareDefaultAndPaletteExposeOnlyPhysicallyValidatedRoutes() throws {
        let line = "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_3_lite product_type=19 native_bridge=true motor_calibrated=false bounded_calibration_pulses=true native_human_tracking=true indicator_palette=true indicator_default_green=false indicator_direct_rgb=false indicator_direct_rgb_mask=0 indicator_basic=true selectable_audio_modes=true supported_audio_mode_mask=55 sound_localization=true requires_measured_attitude_frame=true native_tracking_transport=2 indicator_yellow_state_id=16 indicator_green_state_id=54 indicator_blue_state_id=57 maximum_pan_degrees_per_second=90 maximum_pitch_degrees_per_second=45 nominal_wide_horizontal_fov_degrees=72 firmware=6.5.10.1 serial=ABC123"

        let contract = try XCTUnwrap(OBSBOTDeviceContract.parse(line))

        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .green), 54)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .blue), 57)
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .green))
        XCTAssertEqual(
            SOMALEDSignalSettings(color: .yellow, pattern: .steady)
                .deviceRendering(for: contract),
            .init(stateID: 16, pattern: .steady)
        )
        XCTAssertEqual(
            SOMALEDSignalSettings(color: .blue, pattern: .blink)
                .deviceRendering(for: contract),
            .init(stateID: 57, pattern: .blink)
        )
    }

    func testContractRejectsInconsistentDirectRGBTransport() {
        let line = "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_3_lite product_type=19 native_bridge=true motor_calibrated=false bounded_calibration_pulses=true native_human_tracking=true indicator_palette=true indicator_default_green=true indicator_direct_rgb=false indicator_direct_rgb_mask=4 indicator_basic=true selectable_audio_modes=true supported_audio_mode_mask=55 sound_localization=true requires_measured_attitude_frame=true native_tracking_transport=2 indicator_yellow_state_id=16 indicator_green_state_id=-1 indicator_blue_state_id=57 maximum_pan_degrees_per_second=90 maximum_pitch_degrees_per_second=45 nominal_wide_horizontal_fov_degrees=72 firmware=6.5.10.1 serial=ABC123"

        XCTAssertNil(OBSBOTDeviceContract.parse(line))
    }

    func testContractRejectsIncompleteOrUnsafeNativeAuthority() {
        XCTAssertNil(OBSBOTDeviceContract.parse(
            "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_3_lite native_bridge=true"
        ))
        XCTAssertNil(OBSBOTDeviceContract.parse(
            "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_3_lite native_bridge=true motor_calibrated=false bounded_calibration_pulses=true native_human_tracking=true indicator_palette=true indicator_default_green=true indicator_direct_rgb=false indicator_direct_rgb_mask=0 indicator_basic=true selectable_audio_modes=true supported_audio_mode_mask=55 sound_localization=true requires_measured_attitude_frame=true native_tracking_transport=2 indicator_yellow_state_id=16 indicator_green_state_id=-1 indicator_blue_state_id=57 maximum_pan_degrees_per_second=0 maximum_pitch_degrees_per_second=45 nominal_wide_horizontal_fov_degrees=72"
        ))
    }

    func testCalibrationBindsToGenericAdapterIdentifier() throws {
        let calibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: -1,
            maximumPanDegreesPerSecond: 80,
            maximumPitchDegreesPerSecond: 40,
            deviceIdentifier: "future_obsbot"
        )
        let restored = try JSONDecoder().decode(
            ExternalGimbalCalibration.self,
            from: JSONEncoder().encode(calibration)
        )

        XCTAssertTrue(restored.matches(deviceIdentifier: "future_obsbot"))
        XCTAssertFalse(restored.matches(deviceIdentifier: "tiny_3_lite"))
        XCTAssertNil(restored.deviceProfile)
    }

    func testGeometryCalibrationCanBindToFutureAdapterIdentifier() {
        let calibration = CameraGeometryCalibration(
            deviceProfile: "future_obsbot",
            fovMode: 86,
            imageWidth: 1920,
            imageHeight: 1080,
            projection: .pinhole(horizontalFieldOfViewDegrees: 70),
            capturedFrames: 12,
            fittedPairs: 8,
            fittedMatches: 250,
            validationPairs: 3,
            validationMatches: 100,
            initialRMSEPixels: 8,
            calibratedRMSEPixels: 4,
            calibratedP90Pixels: 8,
            generatedAt: "2026-08-28T00:00:00Z"
        )

        XCTAssertTrue(calibration.isValid)
        XCTAssertTrue(calibration.applies(toDeviceIdentifier: "future_obsbot"))
        XCTAssertFalse(calibration.applies(toDeviceIdentifier: "tiny_3_lite"))
    }
}
