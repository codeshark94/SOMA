import XCTest
@testable import SOMACore

final class NativeTrackingLivenessTests: XCTestCase {
    func testCenteredFaceDoesNotProveNativeTrackingWithoutMeasuredMotion() {
        var monitor = NativeTrackingLiveness()
        let token = monitor.begin(
            target: NormalizedRect(x: 0.42, y: 0.43, width: 0.16, height: 0.16),
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
            at: 1_000_000_000
        )

        XCTAssertEqual(
            monitor.evaluate(
                token: token,
                target: NormalizedRect(x: 0.43, y: 0.42, width: 0.14, height: 0.16),
                pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_200_000_000),
                at: 1_200_000_000
            ),
            .observing
        )
    }

    func testCenteredFaceConfirmsWhenMeasuredMotionKeepsItCentered() {
        var monitor = NativeTrackingLiveness()
        let token = monitor.begin(
            target: NormalizedRect(x: 0.42, y: 0.43, width: 0.16, height: 0.16),
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
            at: 1_000_000_000
        )

        XCTAssertEqual(
            monitor.evaluate(
                token: token,
                target: NormalizedRect(x: 0.43, y: 0.42, width: 0.14, height: 0.16),
                pose: GimbalPose(pitchDegrees: 0.7, panDegrees: 0.4, monotonicNS: 1_200_000_000),
                at: 1_200_000_000
            ),
            .confirmed
        )
    }

    func testOffCenterFaceRequiresMeasuredProgress() {
        var monitor = NativeTrackingLiveness()
        let token = monitor.begin(
            target: NormalizedRect(x: 0.72, y: 0.42, width: 0.12, height: 0.16),
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
            at: 1_000_000_000
        )

        XCTAssertEqual(
            monitor.evaluate(
                token: token,
                target: NormalizedRect(x: 0.55, y: 0.42, width: 0.12, height: 0.16),
                pose: GimbalPose(pitchDegrees: 0, panDegrees: 1.2, monotonicNS: 1_600_000_000),
                at: 1_600_000_000
            ),
            .confirmed
        )
    }

    func testOffCenterFaceTimesOutWhenTheGimbalDoesNotRespond() {
        var monitor = NativeTrackingLiveness(acquisitionTimeoutMilliseconds: 1_000)
        let token = monitor.begin(
            target: NormalizedRect(x: 0.75, y: 0.42, width: 0.12, height: 0.16),
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
            at: 1_000_000_000
        )

        XCTAssertEqual(
            monitor.evaluate(
                token: token,
                target: NormalizedRect(x: 0.75, y: 0.42, width: 0.12, height: 0.16),
                pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 2_000_000_000),
                at: 2_000_000_000
            ),
            .unresponsive
        )
    }
}
