import XCTest
@testable import SOMACore

final class L1ActiveVisionTests: XCTestCase {
    func testCancellationTokenIsMonotonic() {
        let token = L1ActiveVisionCancellationToken()
        XCTAssertFalse(token.isCancelled)

        token.cancel()
        token.cancel()

        XCTAssertTrue(token.isCancelled)
    }

    func testMaterializedVisualSurvivesBackingFileExpiryWithoutEncodingPixels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("capture.jpg")
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        try bytes.write(to: imageURL)
        let resource = L1VisualResource(
            resourceID: "capture:test",
            projection: .currentView,
            localPath: imageURL.path,
            expiresAt: Date().addingTimeInterval(1)
        )
        let materialized = try XCTUnwrap(resource.materializedForInference())
        try FileManager.default.removeItem(at: imageURL)

        XCTAssertEqual(materialized.imageData(at: Date().addingTimeInterval(120)), bytes)
        let encoded = try JSONEncoder().encode(materialized)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(bytes.base64EncodedString()))
        XCTAssertNil(try JSONDecoder().decode(L1VisualResource.self, from: encoded).inlineImageData)
    }

    func testSelectsStrongestCurrentlyGroundedEligibleTarget() {
        let policy = L1ActiveVisionPolicy()
        let selected = policy.selectTarget(label: "Book", from: [
            entity(id: "remembered", label: "book", confidence: 1, observed: false),
            entity(id: "ineligible", label: "book", confidence: 1, eligible: false),
            entity(id: "weak", label: "book", confidence: 0.70, spatial: 0.55),
            entity(id: "grounded", label: " BOOK ", confidence: 0.86, spatial: 0.90),
            entity(id: "other", label: "bottle", confidence: 0.99, spatial: 0.99),
        ])

        XCTAssertEqual(selected?.sceneID, "grounded")
        XCTAssertEqual(policy.fieldOfViewDegrees, 65)
    }

    func testRejectsTargetWithoutCurrentBearing() {
        let policy = L1ActiveVisionPolicy()
        let target = EmbodimentSceneEntity(
            sceneID: "unmapped",
            kind: .object,
            label: "book",
            confidence: 0.95,
            observedThisFrame: true,
            actionEligible: true,
            bearing: nil,
            spatialConfidence: 0,
            lastSeenMilliseconds: 0
        )

        XCTAssertNil(policy.selectTarget(label: "book", from: [target]))
    }

    func testInspectionEvidenceAlwaysRequestsImmediateReflection() {
        XCTAssertTrue(MentalEvidenceKind.activeVisualObservation.demandsImmediateReflection)
    }

    private func entity(
        id: String,
        label: String,
        confidence: Double,
        observed: Bool = true,
        eligible: Bool = true,
        spatial: Double = 0.8
    ) -> EmbodimentSceneEntity {
        EmbodimentSceneEntity(
            sceneID: id,
            kind: .object,
            label: label,
            confidence: confidence,
            observedThisFrame: observed,
            actionEligible: eligible,
            bearing: .init(azimuthDegrees: 4, elevationDegrees: 2),
            spatialConfidence: spatial,
            lastSeenMilliseconds: observed ? 0 : 1_000
        )
    }
}
