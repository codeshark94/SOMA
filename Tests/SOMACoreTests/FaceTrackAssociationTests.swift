import XCTest
@testable import SOMACore

final class FaceTrackAssociationTests: XCTestCase {
    func testFastAdjacentMotionCanPreserveTrackWithoutIoU() {
        let previous = NormalizedRect(x: 0.20, y: 0.25, width: 0.20, height: 0.30)
        let current = NormalizedRect(x: 0.39, y: 0.25, width: 0.20, height: 0.30)

        XCTAssertNotNil(FaceTrackAssociation.score(previous: previous, current: current))
    }

    func testDistantFaceDoesNotAssociate() {
        let previous = NormalizedRect(x: 0.05, y: 0.20, width: 0.18, height: 0.28)
        let current = NormalizedRect(x: 0.75, y: 0.20, width: 0.18, height: 0.28)

        XCTAssertNil(FaceTrackAssociation.score(previous: previous, current: current))
    }

    func testSharpScaleChangeWithoutOverlapDoesNotAssociate() {
        let previous = NormalizedRect(x: 0.20, y: 0.20, width: 0.25, height: 0.35)
        let current = NormalizedRect(x: 0.45, y: 0.20, width: 0.08, height: 0.10)

        XCTAssertNil(FaceTrackAssociation.score(previous: previous, current: current))
    }

    func testSingleVisibleFaceCanContinueAcrossCameraReprojection() {
        let previous = NormalizedRect(x: 0.05, y: 0.20, width: 0.18, height: 0.28)
        let current = NormalizedRect(x: 0.75, y: 0.20, width: 0.18, height: 0.28)

        XCTAssertTrue(FaceTrackAssociation.isPlausibleSingleVisibleContinuation(
            previous: previous,
            current: current
        ))
    }

    func testSingleVisibleContinuationRejectsSharpScaleDiscontinuity() {
        let previous = NormalizedRect(x: 0.05, y: 0.20, width: 0.25, height: 0.35)
        let current = NormalizedRect(x: 0.75, y: 0.20, width: 0.08, height: 0.10)

        XCTAssertFalse(FaceTrackAssociation.isPlausibleSingleVisibleContinuation(
            previous: previous,
            current: current
        ))
    }

    func testAnonymousIdentityAlwaysRequiresFreshRecognition() {
        let policy = FaceIdentityContinuityPolicy()
        XCTAssertEqual(
            policy.action(for: .anonymous, lastValidatedNS: 900_000_000, at: 1_000_000_000),
            .revalidate
        )
    }

    func testEnrolledIdentityIsPeriodicallyRevalidatedAndHasBoundedGrace() {
        let policy = FaceIdentityContinuityPolicy(
            enrolledRevalidationMilliseconds: 1_000,
            enrolledMismatchGraceMilliseconds: 2_500
        )
        XCTAssertEqual(
            policy.action(for: .enrolled, lastValidatedNS: 500_000_000, at: 1_000_000_000),
            .reuse
        )
        XCTAssertEqual(
            policy.action(for: .enrolled, lastValidatedNS: 0, at: 1_000_000_000),
            .revalidate
        )
        XCTAssertTrue(policy.mayBridgeMismatch(lastCorrelatedNS: 0, at: 2_500_000_000))
        XCTAssertFalse(policy.mayBridgeMismatch(lastCorrelatedNS: 0, at: 2_500_000_001))
    }
}
