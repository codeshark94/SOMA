#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class RotatingJSONLStoreTests: XCTestCase {
    func testRotationRetainsNewestSegmentsAcrossRestart() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-jsonl-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let baseURL = directoryURL.appendingPathComponent("detail.jsonl")
        let policy = JSONLRotationPolicy(maximumBytes: 2, retainedFiles: 2)

        let first = try RotatingJSONLStore(baseURL: baseURL, policy: policy)
        for value in ["a\n", "b\n", "c\n", "d\n"] {
            try first.write(Data(value.utf8))
        }
        try first.close()

        var segments = try RotatingJSONLStore.segmentURLs(for: baseURL)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(try String(contentsOf: segments[0], encoding: .utf8), "c\n")
        XCTAssertEqual(try String(contentsOf: segments[1], encoding: .utf8), "d\n")

        let second = try RotatingJSONLStore(baseURL: baseURL, policy: policy)
        try second.write(Data("e\n".utf8))
        try second.close()

        segments = try RotatingJSONLStore.segmentURLs(for: baseURL)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(try String(contentsOf: segments[0], encoding: .utf8), "d\n")
        XCTAssertEqual(try String(contentsOf: segments[1], encoding: .utf8), "e\n")
    }

    func testUnrotatedModeRefusesToOverwriteAnExistingTrace() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-jsonl-single-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let baseURL = directoryURL.appendingPathComponent("trace.jsonl")

        let first = try RotatingJSONLStore(baseURL: baseURL)
        try first.close()
        XCTAssertThrowsError(try RotatingJSONLStore(baseURL: baseURL))
    }
}
#endif
