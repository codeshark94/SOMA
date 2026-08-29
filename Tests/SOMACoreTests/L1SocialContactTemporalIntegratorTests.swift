import XCTest
@testable import SOMACore

final class L1SocialContactTemporalIntegratorTests: XCTestCase {
    func testPassingGlanceDoesNotCreateSocialEpisode() {
        var integrator = L1SocialContactTemporalIntegrator()

        XCTAssertNil(integrator.observe(rawEyeContactActive: true, at: 0))
        XCTAssertNil(integrator.observe(rawEyeContactActive: true, at: 1_000_000_000))
        XCTAssertNil(integrator.observe(rawEyeContactActive: false, at: 1_200_000_000))
        XCTAssertFalse(integrator.snapshot(at: 3_000_000_000).eyeContactActive)
    }

    func testSustainedContactBeginsOnceAfterConfirmation() {
        var integrator = L1SocialContactTemporalIntegrator()

        XCTAssertNil(integrator.observe(rawEyeContactActive: true, at: 1_000_000_000))
        XCTAssertNil(integrator.observe(rawEyeContactActive: true, at: 2_000_000_000))
        XCTAssertEqual(
            integrator.observe(rawEyeContactActive: true, at: 2_500_000_000),
            .began
        )
        XCTAssertNil(integrator.observe(rawEyeContactActive: true, at: 3_000_000_000))
        let snapshot = integrator.snapshot(at: 3_500_000_000)
        XCTAssertTrue(snapshot.eyeContactActive)
        XCTAssertEqual(snapshot.recentEpisodeCount, 1)
        XCTAssertEqual(snapshot.activeDurationSeconds, 1, accuracy: 0.000_001)
    }

    func testBriefDropoutDoesNotEndEpisode() {
        var integrator = L1SocialContactTemporalIntegrator(
            beginConfirmationMilliseconds: 100,
            endConfirmationMilliseconds: 2_000
        )
        _ = integrator.observe(rawEyeContactActive: true, at: 1_000_000_000)
        XCTAssertEqual(
            integrator.observe(rawEyeContactActive: true, at: 1_100_000_000),
            .began
        )

        XCTAssertNil(integrator.observe(rawEyeContactActive: false, at: 2_000_000_000))
        XCTAssertNil(integrator.observe(rawEyeContactActive: true, at: 3_000_000_000))
        XCTAssertTrue(integrator.snapshot(at: 3_000_000_000).eyeContactActive)
    }

    func testSustainedDisengagementEndsOnce() {
        var integrator = L1SocialContactTemporalIntegrator(
            beginConfirmationMilliseconds: 100,
            endConfirmationMilliseconds: 2_000
        )
        _ = integrator.observe(rawEyeContactActive: true, at: 1_000_000_000)
        _ = integrator.observe(rawEyeContactActive: true, at: 1_100_000_000)

        XCTAssertNil(integrator.observe(rawEyeContactActive: false, at: 2_000_000_000))
        XCTAssertNil(integrator.observe(rawEyeContactActive: false, at: 3_000_000_000))
        XCTAssertEqual(
            integrator.observe(rawEyeContactActive: false, at: 4_000_000_000),
            .ended
        )
        XCTAssertNil(integrator.observe(rawEyeContactActive: false, at: 5_000_000_000))
        XCTAssertFalse(integrator.snapshot(at: 5_000_000_000).eyeContactActive)
    }
}
