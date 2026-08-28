#if canImport(XCTest)
import XCTest
@testable import SOMACore

final class FirmwareSoundSourceEstimatorTests: XCTestCase {
    func testSettledTrajectoryProducesMeasuredSoundBearing() throws {
        let start = GimbalPose(pitchDegrees: -3, panDegrees: 11, monotonicNS: 1_000)
        let estimate = try XCTUnwrap(FirmwareSoundSourceEstimator.estimate(
            startingPose: start,
            trajectory: [
                start,
                GimbalPose(pitchDegrees: -2, panDegrees: 28, monotonicNS: 2_000),
                GimbalPose(pitchDegrees: -1, panDegrees: 41, monotonicNS: 3_000),
                GimbalPose(pitchDegrees: -1.1, panDegrees: 42.1, monotonicNS: 4_000),
                GimbalPose(pitchDegrees: -1.0, panDegrees: 41.9, monotonicNS: 5_000),
                GimbalPose(pitchDegrees: -1.0, panDegrees: 42.0, monotonicNS: 6_000),
                GimbalPose(pitchDegrees: -1.0, panDegrees: 42.0, monotonicNS: 7_000),
                GimbalPose(pitchDegrees: -0.9, panDegrees: 41.95, monotonicNS: 8_000),
                GimbalPose(pitchDegrees: -1.0, panDegrees: 42.05, monotonicNS: 9_000),
                GimbalPose(pitchDegrees: -1.0, panDegrees: 42.0, monotonicNS: 10_000),
            ]
        ))

        XCTAssertEqual(estimate.bearing.azimuthDegrees, 42.0, accuracy: 0.001)
        XCTAssertEqual(estimate.bearing.elevationDegrees, -1.0, accuracy: 0.001)
        XCTAssertGreaterThan(estimate.displacementDegrees, 30)
        XCTAssertLessThan(estimate.stabilityDegrees, 0.2)
        XCTAssertGreaterThan(estimate.confidence, 0.8)
    }

    func testInsufficientAttitudeSamplesDoNotInventABearing() {
        let start = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000)
        XCTAssertNil(FirmwareSoundSourceEstimator.estimate(
            startingPose: start,
            trajectory: [
                start,
                GimbalPose(pitchDegrees: 0, panDegrees: 12, monotonicNS: 2_000),
            ]
        ))
    }
}
#endif
