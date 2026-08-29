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
}
