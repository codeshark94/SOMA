import SOMACore
import XCTest

final class LiveDiagnosticsFrameManifestTests: XCTestCase {
    func testManifestRoundTripsOneCaptureGeneration() throws {
        let manifest = LiveDiagnosticsFrameManifest(
            generation: 123_456,
            capturedAtNS: 123_456,
            frameFilename: "frame-123456.jpg",
            visionFilename: "vision-123456.json"
        )

        let decoded = try JSONDecoder().decode(
            LiveDiagnosticsFrameManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded, manifest)
        XCTAssertTrue(decoded.containsOnlyFilenames)
        XCTAssertTrue(decoded.filenamesMatchGeneration)
    }

    func testManifestRejectsPathComponents() {
        let manifest = LiveDiagnosticsFrameManifest(
            generation: 1,
            capturedAtNS: 1,
            frameFilename: "../frame-1.jpg",
            visionFilename: "vision-1.json"
        )

        XCTAssertFalse(manifest.containsOnlyFilenames)
    }

    func testManifestRejectsFilenamesFromAnotherGeneration() {
        let manifest = LiveDiagnosticsFrameManifest(
            generation: 1,
            capturedAtNS: 1,
            frameFilename: "frame-2.jpg",
            visionFilename: "vision-2.json"
        )

        XCTAssertFalse(manifest.filenamesMatchGeneration)
    }
}
