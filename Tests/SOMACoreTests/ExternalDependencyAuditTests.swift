import XCTest
@testable import SOMACore

final class ExternalDependencyAuditTests: XCTestCase {
    func testParsesDoctorOutputAndDeduplicatesRepeatedFailures() {
        let audit = ExternalDependencyAudit.parse(
            output: """
            ok   canonical SOMA branding and packaged icon assets
            ok   Ollama 0.33.2
            warn optional ArcFace identity model is not installed
            fail missing usable code-signing identity
            fail missing usable code-signing identity
            SOMA preflight failed with 1 blocking issue(s) and 1 warning(s).
            """,
            exitStatus: 1
        )

        XCTAssertEqual(audit.passedCount, 1)
        XCTAssertEqual(audit.warningCount, 1)
        XCTAssertEqual(audit.failedCount, 1)
        XCTAssertFalse(audit.isReady)
        XCTAssertEqual(audit.checks.map(\.detail), [
            "Ollama 0.33.2",
            "optional ArcFace identity model is not installed",
            "missing usable code-signing identity",
        ])
    }

    func testInternalSOMASelfChecksAreNotPresentedAsExternalDependencies() {
        let audit = ExternalDependencyAudit.parse(
            output: """
            ok   canonical SOMA branding and packaged icon assets
            fail SOMA branding assets are missing
            ok   OpenCV 5.0.0 at /opt/homebrew/opt/opencv
            """,
            exitStatus: 1
        )

        XCTAssertEqual(audit.checks.map(\.detail), [
            "OpenCV 5.0.0 at /opt/homebrew/opt/opencv",
        ])
        XCTAssertTrue(audit.isReady)
    }

    func testReadyRequiresSuccessfulProcessAndNoFailedCheck() {
        let audit = ExternalDependencyAudit.parse(
            output: "ok   Hermes Agent v0.20.6\nok   connected OBSBOT USB device",
            exitStatus: 0
        )

        XCTAssertTrue(audit.isReady)
        XCTAssertEqual(audit.passedCount, 2)
        XCTAssertEqual(audit.warningCount, 0)
        XCTAssertEqual(audit.failedCount, 0)
    }
}
