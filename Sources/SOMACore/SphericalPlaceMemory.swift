import Foundation

public enum SphericalPlaceMemoryError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// A versioned local scene embedding. The payload is a normalized Float32
/// vector encoded by Codable as base64; it contains no image pixels, labels,
/// people, or scene entities. Encoder identity is part of compatibility so a
/// model or OS revision change cannot silently merge unrelated places.
public struct PanoramaPlaceEmbedding: Codable, Equatable, Sendable {
    public static let appleVisionFeaturePrintEncoder = "apple_vision_feature_print"
    public static let cpuSpatialSignatureEncoder = "cpu_spatial_signature"
    public static let maximumElementCount = 4_096

    public let encoder: String
    public let revision: Int
    public let elementCount: Int
    private let float32LittleEndian: Data

    public init?(encoder: String, revision: Int, values: [Float]) {
        let boundedEncoder = String(encoder.prefix(64))
        guard !boundedEncoder.isEmpty,
              (1...10_000).contains(revision),
              (8...Self.maximumElementCount).contains(values.count),
              values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0.000_001 else { return nil }
        let normalized = values.map { Float(Double($0) / norm) }
        var payload = Data(capacity: normalized.count * MemoryLayout<UInt32>.size)
        for value in normalized {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        self.encoder = boundedEncoder
        self.revision = revision
        elementCount = normalized.count
        float32LittleEndian = payload
    }

    public var values: [Float] {
        float32LittleEndian.withUnsafeBytes { bytes in
            (0..<elementCount).map { index in
                let bits = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    public func isCompatible(with other: PanoramaPlaceEmbedding) -> Bool {
        encoder == other.encoder
            && revision == other.revision
            && elementCount == other.elementCount
    }

    public func similarity(to other: PanoramaPlaceEmbedding) -> Double? {
        guard isCompatible(with: other) else { return nil }
        let lhs = values
        let rhs = other.values
        let dot = lhs.indices.reduce(0.0) {
            $0 + Double(lhs[$1]) * Double(rhs[$1])
        }
        return min(max((dot + 1) / 2, 0), 1)
    }

    public func blended(with observed: PanoramaPlaceEmbedding, weight: Double) -> PanoramaPlaceEmbedding? {
        guard isCompatible(with: observed) else { return nil }
        let boundedWeight = min(max(weight, 0), 1)
        let current = values
        let next = observed.values
        return PanoramaPlaceEmbedding(
            encoder: encoder,
            revision: revision,
            values: current.indices.map {
                Float(Double(current[$0]) * (1 - boundedWeight) + Double(next[$0]) * boundedWeight)
            }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case encoder
        case revision
        case elementCount
        case float32LittleEndian
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let encoder = try values.decode(String.self, forKey: .encoder)
        let revision = try values.decode(Int.self, forKey: .revision)
        let elementCount = try values.decode(Int.self, forKey: .elementCount)
        let payload = try values.decode(Data.self, forKey: .float32LittleEndian)
        guard !encoder.isEmpty,
              encoder.count <= 64,
              (1...10_000).contains(revision),
              (8...Self.maximumElementCount).contains(elementCount),
              payload.count == elementCount * MemoryLayout<UInt32>.size else {
            throw SphericalPlaceMemoryError.invalid("invalid place embedding metadata")
        }
        self.encoder = encoder
        self.revision = revision
        self.elementCount = elementCount
        float32LittleEndian = payload
        let decodedValues = self.values
        let norm = sqrt(decodedValues.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard decodedValues.allSatisfy(\.isFinite), abs(norm - 1) <= 0.001 else {
            throw SphericalPlaceMemoryError.invalid("place embedding contains invalid values or norm")
        }
    }
}

public struct SphericalPlaceMemoryCell: Codable, Equatable, Sendable {
    public let bearing: GimbalRelativeBearing
    public let embedding: PanoramaPlaceEmbedding
    public let familiarity: Double
    public let conflict: Double
    public let observationCount: Int

    public init(
        bearing: GimbalRelativeBearing,
        embedding: PanoramaPlaceEmbedding,
        familiarity: Double,
        conflict: Double,
        observationCount: Int
    ) {
        self.bearing = bearing
        self.embedding = embedding
        self.familiarity = min(max(familiarity, 0), 1)
        self.conflict = min(max(conflict, 0), 1)
        self.observationCount = min(max(observationCount, 1), 1_000_000)
    }
}

public struct SphericalPlaceMemorySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAtUnixMilliseconds: UInt64
    public let cells: [SphericalPlaceMemoryCell]

    public init(generatedAtUnixMilliseconds: UInt64, cells: [SphericalPlaceMemoryCell]) {
        schemaVersion = 1
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.cells = Array(cells.prefix(256))
    }

    public func validated(expectedEncoder: String, expectedRevision: Int) throws -> SphericalPlaceMemorySnapshot {
        guard schemaVersion == 1, cells.count <= 256 else {
            throw SphericalPlaceMemoryError.invalid("unsupported spherical place memory schema")
        }
        guard cells.allSatisfy({
            $0.embedding.encoder == expectedEncoder
                && $0.embedding.revision == expectedRevision
                && $0.bearing.azimuthDegrees.isFinite
                && $0.bearing.elevationDegrees.isFinite
                && (-180...180).contains($0.bearing.azimuthDegrees)
                && (-90...90).contains($0.bearing.elevationDegrees)
                && $0.observationCount > 0
                && $0.observationCount <= 1_000_000
                && (0...1).contains($0.familiarity)
                && (0...1).contains($0.conflict)
        }) else {
            throw SphericalPlaceMemoryError.invalid("place memory encoder, revision, or bearing is incompatible")
        }
        let uniqueBearings = Set(cells.map {
            "\($0.bearing.azimuthDegrees):\($0.bearing.elevationDegrees)"
        })
        guard uniqueBearings.count == cells.count else {
            throw SphericalPlaceMemoryError.invalid("place memory contains duplicate spherical cells")
        }
        return self
    }
}

public enum SphericalPlaceMemoryFile {
    private static let maximumBytes = 4 * 1_024 * 1_024

    public static func load(
        from url: URL,
        expectedEncoder: String,
        expectedRevision: Int
    ) throws -> SphericalPlaceMemorySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw SphericalPlaceMemoryError.invalid("place memory exceeds 4 MiB")
        }
        return try JSONDecoder().decode(SphericalPlaceMemorySnapshot.self, from: data)
            .validated(expectedEncoder: expectedEncoder, expectedRevision: expectedRevision)
    }

    public static func write(_ snapshot: SphericalPlaceMemorySnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else {
            throw SphericalPlaceMemoryError.invalid("place memory exceeds 4 MiB")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
