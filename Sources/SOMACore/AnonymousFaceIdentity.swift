import CryptoKit
import Foundation

public enum AnonymousFaceRegistryError: Error, Equatable, Sendable {
    case corruptStore
    case invalidCalibration
    case invalidHandle
    case unknownHandle
    case insufficientEnrollmentEvidence
}

/// A per-install pseudonym. It is derived from a random internal cluster ID,
/// not directly from biometric values, so it is stable locally without being
/// usable as a cross-system face fingerprint.
public struct AnonymousFaceHandle: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.count == 37,
              rawValue.hasPrefix("anon_"),
              rawValue.dropFirst(5).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw AnonymousFaceRegistryError.invalidHandle
        }
        self.rawValue = rawValue
    }
}

public struct AnonymousFaceCalibration: Equatable, Sendable {
    public let minimumCosineSimilarity: Double
    public let minimumBestAlternativeMargin: Double
    public let minimumObservationQuality: Double
    public let confirmationsRequired: Int
    public let evidenceWindowMilliseconds: UInt64
    public let retentionDays: Int
    public let maximumClusters: Int
    public let maximumReferencesPerCluster: Int

    public init(
        minimumCosineSimilarity: Double,
        minimumBestAlternativeMargin: Double,
        minimumObservationQuality: Double,
        confirmationsRequired: Int = 3,
        evidenceWindowMilliseconds: UInt64 = 1_200,
        retentionDays: Int = 30,
        maximumClusters: Int = 512,
        maximumReferencesPerCluster: Int = 8
    ) throws {
        guard minimumCosineSimilarity.isFinite,
              (-1 ... 1).contains(minimumCosineSimilarity),
              minimumBestAlternativeMargin.isFinite,
              (0 ... 2).contains(minimumBestAlternativeMargin),
              minimumObservationQuality.isFinite,
              (0 ... 1).contains(minimumObservationQuality),
              (2 ... 12).contains(confirmationsRequired),
              evidenceWindowMilliseconds > 0,
              (1 ... 3_650).contains(retentionDays),
              (1 ... 4_096).contains(maximumClusters),
              (2 ... 24).contains(maximumReferencesPerCluster) else {
            throw AnonymousFaceRegistryError.invalidCalibration
        }
        self.minimumCosineSimilarity = minimumCosineSimilarity
        self.minimumBestAlternativeMargin = minimumBestAlternativeMargin
        self.minimumObservationQuality = minimumObservationQuality
        self.confirmationsRequired = confirmationsRequired
        self.evidenceWindowMilliseconds = evidenceWindowMilliseconds
        self.retentionDays = retentionDays
        self.maximumClusters = maximumClusters
        self.maximumReferencesPerCluster = maximumReferencesPerCluster
    }
}

public enum AnonymousFaceDecision: Equatable, Sendable {
    case rejected
    case candidate(handle: AnonymousFaceHandle, confirmations: Int)
    case recognized(handle: AnonymousFaceHandle, similarity: Double, observationCount: Int)

    public var handle: AnonymousFaceHandle? {
        switch self {
        case .rejected: nil
        case let .candidate(handle, _), let .recognized(handle, _, _): handle
        }
    }

    public var isRecognized: Bool {
        if case .recognized = self { return true }
        return false
    }
}

private struct AnonymousFaceCluster: Codable {
    let clusterID: UUID
    let handle: AnonymousFaceHandle
    var references: [LocalFaceEmbedding]
    let firstSeenAt: Date
    var lastSeenAt: Date
    var observationCount: Int
}

private struct PendingAnonymousFaceCluster {
    let clusterID: UUID
    let handle: AnonymousFaceHandle
    var references: [LocalFaceEmbedding]
    let firstSeenAt: Date
    var lastSeenAt: Date
    var lastObservedNS: UInt64
    var confirmations: Int
}

private struct AnonymousFaceEnvelope: Codable {
    let schemaVersion: Int
    let algorithm: String
    let ciphertext: String
}

private struct AnonymousFaceSnapshot: Codable {
    let schemaVersion: Int
    let clusters: [AnonymousFaceCluster]
}

/// Local open-set clustering for people who have not supplied an identity.
/// A cluster becomes durable only after repeated, compatible observations.
/// Stored prototypes are encrypted; callers receive only an opaque HMAC
/// handle and never the biometric vector or the internal UUID.
public actor AnonymousFaceRegistry {
    public static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encryptionKey: SymmetricKey
    private let handleKey: SymmetricKey
    private let calibration: AnonymousFaceCalibration
    private var clustersByID: [UUID: AnonymousFaceCluster]
    private var pending: [PendingAnonymousFaceCluster] = []
    private var lastPersistedAtByID: [UUID: Date] = [:]

    public init(
        fileURL: URL,
        encryptionKey: CognitiveMemoryEncryptionKey,
        calibration: AnonymousFaceCalibration
    ) throws {
        self.fileURL = fileURL
        self.calibration = calibration
        self.encryptionKey = SymmetricKey(data: encryptionKey.rawRepresentation)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: encryptionKey.rawRepresentation),
            salt: Data("SOMA.AnonymousFaceRegistry.v1".utf8),
            info: Data("opaque-handle".utf8),
            outputByteCount: 32
        )
        handleKey = derived
        clustersByID = try Self.load(fileURL: fileURL, key: self.encryptionKey)
        guard clustersByID.count <= calibration.maximumClusters else {
            throw AnonymousFaceRegistryError.corruptStore
        }
    }

    public func observe(
        _ embedding: LocalFaceEmbedding,
        at monotonicNS: UInt64,
        date: Date = Date()
    ) throws -> AnonymousFaceDecision {
        guard embedding.quality >= calibration.minimumObservationQuality else {
            return .rejected
        }
        expirePending(at: monotonicNS)
        try pruneExpired(at: date)

        let persistedScores = scores(for: embedding, clusters: Array(clustersByID.values))
        if case let .confident(clusterID, similarity) = classify(persistedScores),
           var cluster = clustersByID[clusterID] {
            cluster.lastSeenAt = date
            cluster.observationCount += 1
            let referenceSetChanged = appendReference(embedding, to: &cluster.references)
            clustersByID[clusterID] = cluster
            if referenceSetChanged || shouldPersist(clusterID: clusterID, at: date) {
                try persist()
                lastPersistedAtByID[clusterID] = date
            }
            return .recognized(
                handle: cluster.handle,
                similarity: similarity,
                observationCount: cluster.observationCount
            )
        }
        if case .ambiguous = classify(persistedScores) { return .rejected }

        let pendingScores = scores(for: embedding, pending: pending)
        if case let .confident(clusterID, _) = classify(pendingScores),
           let index = pending.firstIndex(where: { $0.clusterID == clusterID }) {
            pending[index].confirmations += 1
            pending[index].lastObservedNS = monotonicNS
            pending[index].lastSeenAt = date
            appendReference(embedding, to: &pending[index].references)
            if pending[index].confirmations >= calibration.confirmationsRequired {
                let promoted = AnonymousFaceCluster(
                    clusterID: pending[index].clusterID,
                    handle: pending[index].handle,
                    references: pending[index].references,
                    firstSeenAt: pending[index].firstSeenAt,
                    lastSeenAt: date,
                    observationCount: pending[index].confirmations
                )
                pending.remove(at: index)
                makeRoomForClusterIfNeeded()
                clustersByID[promoted.clusterID] = promoted
                try persist()
                lastPersistedAtByID[promoted.clusterID] = date
                return .recognized(
                    handle: promoted.handle,
                    similarity: 1,
                    observationCount: promoted.observationCount
                )
            }
            return .candidate(
                handle: pending[index].handle,
                confirmations: pending[index].confirmations
            )
        }
        if case .ambiguous = classify(pendingScores) { return .rejected }

        let clusterID = UUID()
        let handle = try makeHandle(clusterID: clusterID)
        pending.append(PendingAnonymousFaceCluster(
            clusterID: clusterID,
            handle: handle,
            references: [embedding],
            firstSeenAt: date,
            lastSeenAt: date,
            lastObservedNS: monotonicNS,
            confirmations: 1
        ))
        if pending.count > 64 {
            pending.removeFirst(pending.count - 64)
        }
        return .candidate(handle: handle, confirmations: 1)
    }

    public func persistentHandles() -> [AnonymousFaceHandle] {
        clustersByID.values.map(\.handle).sorted { $0.rawValue < $1.rawValue }
    }

    /// Per-cluster counts for local diagnostics. Handles and embeddings remain
    /// private; callers can only verify that distinct-view retention is active.
    public func persistentReferenceCounts() -> [Int] {
        clustersByID.values
            .sorted { $0.handle.rawValue < $1.handle.rawValue }
            .map { $0.references.count }
    }

    /// Returns only already-encrypted local recognition references for an
    /// explicit enrollment transition. Callers must not serialize these values
    /// into traces, remote context, or general memory.
    public func enrollmentReferences(for handle: AnonymousFaceHandle) throws -> [LocalFaceEmbedding] {
        guard let cluster = clustersByID.values.first(where: { $0.handle == handle }) else {
            throw AnonymousFaceRegistryError.unknownHandle
        }
        guard cluster.references.count >= 2 else {
            throw AnonymousFaceRegistryError.insufficientEnrollmentEvidence
        }
        return cluster.references
    }

    public func forget(_ handle: AnonymousFaceHandle) throws {
        let ids = clustersByID.values.filter { $0.handle == handle }.map(\.clusterID)
        guard !ids.isEmpty else { return }
        ids.forEach { clustersByID.removeValue(forKey: $0) }
        try persist()
    }

    private enum MatchClassification {
        case none
        case ambiguous
        case confident(UUID, Double)
    }

    private func classify(_ scores: [(UUID, Double)]) -> MatchClassification {
        guard let best = scores.first,
              best.1 >= calibration.minimumCosineSimilarity else { return .none }
        let alternative = scores.dropFirst().first?.1 ?? -1
        guard best.1 - alternative >= calibration.minimumBestAlternativeMargin else {
            return .ambiguous
        }
        return .confident(best.0, best.1)
    }

    private func scores(
        for embedding: LocalFaceEmbedding,
        clusters: [AnonymousFaceCluster]
    ) -> [(UUID, Double)] {
        clusters.compactMap { cluster in
            compatibleMaximum(embedding, references: cluster.references).map { (cluster.clusterID, $0) }
        }.sorted { $0.1 > $1.1 }
    }

    private func scores(
        for embedding: LocalFaceEmbedding,
        pending: [PendingAnonymousFaceCluster]
    ) -> [(UUID, Double)] {
        pending.compactMap { cluster in
            compatibleMaximum(embedding, references: cluster.references).map { (cluster.clusterID, $0) }
        }.sorted { $0.1 > $1.1 }
    }

    private func compatibleMaximum(
        _ embedding: LocalFaceEmbedding,
        references: [LocalFaceEmbedding]
    ) -> Double? {
        references
            .filter {
                $0.modelID == embedding.modelID
                    && $0.modelRevision == embedding.modelRevision
                    && $0.values.count == embedding.values.count
            }
            .compactMap { try? embedding.cosineSimilarity(to: $0) }
            .max()
    }

    @discardableResult
    private func appendReference(
        _ embedding: LocalFaceEmbedding,
        to references: inout [LocalFaceEmbedding]
    ) -> Bool {
        LocalFaceReferenceSet.retain(
            embedding,
            in: &references,
            maximumCount: calibration.maximumReferencesPerCluster
        )
    }

    private func makeHandle(clusterID: UUID) throws -> AnonymousFaceHandle {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(clusterID.uuidString.lowercased().utf8),
            using: handleKey
        )
        let prefix = authentication.prefix(16).map { String(format: "%02x", $0) }.joined()
        return try AnonymousFaceHandle(rawValue: "anon_\(prefix)")
    }

    private func expirePending(at monotonicNS: UInt64) {
        let window = calibration.evidenceWindowMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !window.overflow else { return }
        pending.removeAll {
            monotonicNS < $0.lastObservedNS || monotonicNS - $0.lastObservedNS > window.partialValue
        }
    }

    private func pruneExpired(at date: Date) throws {
        let cutoff = date.addingTimeInterval(-Double(calibration.retentionDays) * 86_400)
        let expired = clustersByID.values.filter { $0.lastSeenAt < cutoff }.map(\.clusterID)
        guard !expired.isEmpty else { return }
        expired.forEach {
            clustersByID.removeValue(forKey: $0)
            lastPersistedAtByID.removeValue(forKey: $0)
        }
        try persist()
    }

    private func makeRoomForClusterIfNeeded() {
        guard clustersByID.count >= calibration.maximumClusters,
              let oldest = clustersByID.values.min(by: { $0.lastSeenAt < $1.lastSeenAt }) else { return }
        clustersByID.removeValue(forKey: oldest.clusterID)
        lastPersistedAtByID.removeValue(forKey: oldest.clusterID)
    }

    private func shouldPersist(clusterID: UUID, at date: Date) -> Bool {
        guard let last = lastPersistedAtByID[clusterID] else { return true }
        return date.timeIntervalSince(last) >= 60
    }

    private func persist() throws {
        let snapshot = AnonymousFaceSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            clusters: clustersByID.values.sorted { $0.handle.rawValue < $1.handle.rawValue }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let plaintext = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: encryptionKey)
        guard let combined = sealed.combined else {
            throw AnonymousFaceRegistryError.corruptStore
        }
        let envelope = AnonymousFaceEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            algorithm: "AES.GCM.256",
            ciphertext: combined.base64EncodedString()
        )
        let data = try encoder.encode(envelope)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func load(
        fileURL: URL,
        key: SymmetricKey
    ) throws -> [UUID: AnonymousFaceCluster] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= 32 * 1_048_576 else { throw AnonymousFaceRegistryError.corruptStore }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(AnonymousFaceEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.currentSchemaVersion,
                  envelope.algorithm == "AES.GCM.256",
                  let combined = Data(base64Encoded: envelope.ciphertext) else {
                throw AnonymousFaceRegistryError.corruptStore
            }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
            let snapshot = try decoder.decode(AnonymousFaceSnapshot.self, from: plaintext)
            guard snapshot.schemaVersion == Self.currentSchemaVersion,
                  Set(snapshot.clusters.map(\.clusterID)).count == snapshot.clusters.count,
                  Set(snapshot.clusters.map(\.handle)).count == snapshot.clusters.count,
                  snapshot.clusters.allSatisfy({ !$0.references.isEmpty && $0.observationCount > 0 }) else {
                throw AnonymousFaceRegistryError.corruptStore
            }
            return Dictionary(uniqueKeysWithValues: snapshot.clusters.map { ($0.clusterID, $0) })
        } catch let error as AnonymousFaceRegistryError {
            throw error
        } catch {
            throw AnonymousFaceRegistryError.corruptStore
        }
    }
}
