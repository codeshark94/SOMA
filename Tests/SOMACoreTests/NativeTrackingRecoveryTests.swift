import XCTest
@testable import SOMACore

final class NativeTrackingRecoveryTests: XCTestCase {
    func testFreshHumanEvidenceCancelsReacquisition() {
        var recovery = NativeTrackingRecovery(
            stationaryConfirmationMilliseconds: 300,
            maximumRecoveryMilliseconds: 2_000
        )
        recovery.recordHumanObservation(at: 1_000_000_000)

        XCTAssertEqual(
            recovery.evaluateAbsence(
                at: 1_300_000_000,
                measuredVelocity: GimbalVelocityFeedback(
                    pitchDegreesPerSecond: 0,
                    panDegreesPerSecond: 12
                )
            ),
            .reacquiring
        )

        recovery.recordHumanObservation(at: 1_400_000_000)
        XCTAssertEqual(recovery.state, .tracking)
    }

    func testStationaryNativeTrackerConfirmsLossWithoutLongStall() {
        var recovery = NativeTrackingRecovery(
            stationaryConfirmationMilliseconds: 300,
            maximumRecoveryMilliseconds: 2_000,
            stationaryAngularSpeedDegreesPerSecond: 0.8
        )
        recovery.recordHumanObservation(at: 1_000_000_000)
        let stopped = GimbalVelocityFeedback(
            pitchDegreesPerSecond: 0.1,
            panDegreesPerSecond: 0.2
        )

        XCTAssertEqual(
            recovery.evaluateAbsence(at: 1_250_000_000, measuredVelocity: stopped),
            .reacquiring
        )
        XCTAssertEqual(
            recovery.evaluateAbsence(at: 1_550_000_000, measuredVelocity: stopped),
            .targetLost
        )
    }

    func testMeasuredRecoveryMotionRetainsLeaseWithinBound() {
        var recovery = NativeTrackingRecovery(
            stationaryConfirmationMilliseconds: 300,
            maximumRecoveryMilliseconds: 2_000
        )
        recovery.recordHumanObservation(at: 1_000_000_000)
        let moving = GimbalVelocityFeedback(
            pitchDegreesPerSecond: 2,
            panDegreesPerSecond: 18
        )

        XCTAssertEqual(
            recovery.evaluateAbsence(at: 1_500_000_000, measuredVelocity: moving),
            .reacquiring
        )
        XCTAssertEqual(
            recovery.evaluateAbsence(at: 2_999_000_000, measuredVelocity: moving),
            .reacquiring
        )
        XCTAssertEqual(
            recovery.evaluateAbsence(at: 3_000_000_000, measuredVelocity: moving),
            .targetLost
        )
    }

    func testMissingMotionFeedbackUsesBoundedDeadline() {
        var recovery = NativeTrackingRecovery(
            stationaryConfirmationMilliseconds: 300,
            maximumRecoveryMilliseconds: 1_000
        )
        recovery.recordHumanObservation(at: 1_000_000_000)

        XCTAssertEqual(
            recovery.evaluateAbsence(at: 1_500_000_000, measuredVelocity: nil),
            .reacquiring
        )
        XCTAssertEqual(
            recovery.evaluateAbsence(at: 2_000_000_000, measuredVelocity: nil),
            .targetLost
        )
    }
}
