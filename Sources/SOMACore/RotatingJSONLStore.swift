import Foundation

public struct JSONLRotationPolicy: Sendable, Equatable {
    public let maximumBytes: Int
    public let retainedFiles: Int

    public init(maximumBytes: Int, retainedFiles: Int) {
        precondition(maximumBytes > 0, "maximumBytes must be positive")
        precondition(retainedFiles > 0, "retainedFiles must be positive")
        self.maximumBytes = maximumBytes
        self.retainedFiles = retainedFiles
    }
}

/// A single-writer JSONL sink. With a rotation policy, the supplied URL is a
/// stable basename and numbered segments are retained across process restarts.
public final class RotatingJSONLStore {
    public private(set) var currentURL: URL

    private let baseURL: URL
    private let policy: JSONLRotationPolicy?
    private var handle: FileHandle
    private var bytesWritten: Int
    private var sequence: UInt64

    public init(baseURL: URL, policy: JSONLRotationPolicy? = nil) throws {
        self.baseURL = baseURL
        self.policy = policy
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: baseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let policy {
            let nextSequence = try Self.nextSequence(for: baseURL, fileManager: fileManager)
            sequence = nextSequence
            currentURL = Self.segmentURL(for: baseURL, sequence: nextSequence)
            guard fileManager.createFile(atPath: currentURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: currentURL)
            bytesWritten = 0
            try Self.pruneSegments(for: baseURL, retaining: policy.retainedFiles, fileManager: fileManager)
        } else {
            guard !fileManager.fileExists(atPath: baseURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            sequence = 0
            currentURL = baseURL
            guard fileManager.createFile(atPath: baseURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: baseURL)
            bytesWritten = 0
        }
    }

    deinit {
        try? handle.close()
    }

    public func write(_ data: Data) throws {
        if let policy,
           bytesWritten > 0,
           bytesWritten + data.count > policy.maximumBytes {
            try rotate(policy: policy)
        }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    public func close() throws {
        try handle.close()
    }

    public static func segmentURLs(for baseURL: URL) throws -> [URL] {
        try matchingSegments(for: baseURL, fileManager: .default).map(\.url)
    }

    private func rotate(policy: JSONLRotationPolicy) throws {
        try handle.close()
        sequence += 1
        let nextURL = Self.segmentURL(for: baseURL, sequence: sequence)
        guard FileManager.default.createFile(atPath: nextURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        currentURL = nextURL
        handle = try FileHandle(forWritingTo: nextURL)
        bytesWritten = 0
        try Self.pruneSegments(
            for: baseURL,
            retaining: policy.retainedFiles,
            fileManager: .default
        )
    }

    private static func nextSequence(for baseURL: URL, fileManager: FileManager) throws -> UInt64 {
        let segments = try matchingSegments(for: baseURL, fileManager: fileManager)
        return (segments.map(\.sequence).max() ?? 0) + 1
    }

    private static func pruneSegments(
        for baseURL: URL,
        retaining retainedFiles: Int,
        fileManager: FileManager
    ) throws {
        let segments = try matchingSegments(for: baseURL, fileManager: fileManager)
        for segment in segments.dropLast(retainedFiles) {
            try fileManager.removeItem(at: segment.url)
        }
    }

    private static func matchingSegments(
        for baseURL: URL,
        fileManager: FileManager
    ) throws -> [(sequence: UInt64, url: URL)] {
        let directoryURL = baseURL.deletingLastPathComponent()
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension
        let prefix = "\(stem)-"
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            let endIndex = suffix.isEmpty ? name.endIndex : name.index(name.endIndex, offsetBy: -suffix.count)
            let sequenceText = name[name.index(name.startIndex, offsetBy: prefix.count)..<endIndex]
            guard sequenceText.count == 8, let sequence = UInt64(sequenceText) else { return nil }
            return (sequence, url)
        }
        .sorted { $0.sequence < $1.sequence }
    }

    private static func segmentURL(for baseURL: URL, sequence: UInt64) -> URL {
        let directoryURL = baseURL.deletingLastPathComponent()
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension
        let filename = String(format: "%@-%08llu", stem, sequence)
        return directoryURL
            .appendingPathComponent(filename)
            .appendingPathExtension(pathExtension)
    }
}
