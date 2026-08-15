import Foundation
import SOMACore
import XCTest

final class SphericalPlaceMemoryTests: XCTestCase {
    func testPlaceMemoryRoundTripIsBoundedPrivateAndContainsOnlySpatialEmbeddings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-place-memory-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("places.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let embedding = try XCTUnwrap(PanoramaPlaceEmbedding(
            encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            revision: 2,
            values: Array(1...32).map(Float.init)
        ))
        let snapshot = SphericalPlaceMemorySnapshot(
            generatedAtUnixMilliseconds: 123,
            cells: [SphericalPlaceMemoryCell(
                bearing: GimbalRelativeBearing(azimuthDegrees: 18, elevationDegrees: -13),
                embedding: embedding,
                familiarity: 0.8,
                conflict: 0.2,
                observationCount: 4
            )]
        )
        try SphericalPlaceMemoryFile.write(snapshot, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let data = try Data(contentsOf: url)
        XCTAssertLessThan(data.count, 4 * 1_024 * 1_024)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["cells", "generatedAtUnixMilliseconds", "schemaVersion"])
        let cells = try XCTUnwrap(object["cells"] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(cells.first).keys),
            ["bearing", "conflict", "embedding", "familiarity", "observationCount"]
        )

        let loaded = try XCTUnwrap(SphericalPlaceMemoryFile.load(
            from: url,
            expectedEncoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            expectedRevision: 2
        ))
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.cells.first?.embedding.similarity(to: embedding) ?? 0, 1, accuracy: 0.000_001)
    }

    func testPlaceMemoryRejectsAnEncoderRevisionMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-place-memory-mismatch-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("places.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedding = try XCTUnwrap(PanoramaPlaceEmbedding(
            encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            revision: 2,
            values: Array(repeating: 1, count: 16)
        ))
        try SphericalPlaceMemoryFile.write(
            SphericalPlaceMemorySnapshot(
                generatedAtUnixMilliseconds: 123,
                cells: [SphericalPlaceMemoryCell(
                    bearing: GimbalRelativeBearing(azimuthDegrees: 0, elevationDegrees: 0),
                    embedding: embedding,
                    familiarity: 1,
                    conflict: 0,
                    observationCount: 2
                )]
            ),
            to: url
        )
        XCTAssertThrowsError(try SphericalPlaceMemoryFile.load(
            from: url,
            expectedEncoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            expectedRevision: 3
        ))
    }
}
