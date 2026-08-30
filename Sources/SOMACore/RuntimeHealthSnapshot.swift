import Foundation

public enum RuntimeHealthProjectionPolicy {
    private static let lifecycleStates: Set<String> = [
        "available", "capabilities_ready", "configured", "consciousness_configured",
        "disabled", "loaded", "profile_preflight", "ready", "recovered", "rejected",
        "started", "starting", "stopped",
    ]
    private static let readinessFaults: [String: Set<String>] = [
        "attention_gimbal_bridge": ["fault", "lifecycle_shutdown_failed"],
        "control_settings": ["rejected"],
        "face_identity": ["unavailable"],
        "face_neural_engine": ["runtime_error", "runtime_stalled", "unavailable"],
    ]

    /// Keeps durable lifecycle changes while excluding high-rate measurement
    /// states such as alignments, sampled waypoints, and inference detail.
    public static func retains(source: String, state: String) -> Bool {
        if source == "social_indicator" { return true }
        if lifecycleStates.contains(state) { return true }
        return readinessFaults[source]?.contains(state) == true
    }
}

public struct RuntimeHealthSnapshot: Codable, Equatable, Sendable {
    public struct SourceState: Codable, Equatable, Sendable {
        public let state: String
        public let monotonicNS: UInt64

        public init(state: String, monotonicNS: UInt64) {
            self.state = state
            self.monotonicNS = monotonicNS
        }
    }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generationID: UUID
    public let processID: Int
    public let startedAtEpochMS: Int64
    public let updatedAtEpochMS: Int64
    public let sources: [String: SourceState]

    public init(
        schemaVersion: Int = RuntimeHealthSnapshot.currentSchemaVersion,
        generationID: UUID,
        processID: Int,
        startedAtEpochMS: Int64,
        updatedAtEpochMS: Int64,
        sources: [String: SourceState]
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.processID = processID
        self.startedAtEpochMS = startedAtEpochMS
        self.updatedAtEpochMS = updatedAtEpochMS
        self.sources = sources
    }

    public static func load(from fileURL: URL) throws -> RuntimeHealthSnapshot {
        let snapshot = try JSONDecoder().decode(
            RuntimeHealthSnapshot.self,
            from: Data(contentsOf: fileURL, options: .mappedIfSafe)
        )
        guard snapshot.schemaVersion == currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }
}

/// A bounded current-state projection for status surfaces. The high-rate JSONL
/// trace remains the audit record; this file only preserves the latest durable
/// state per subsystem so startup facts do not disappear behind video events.
public final class RuntimeHealthSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let generationID: UUID
    private let processID: Int
    private let startedAtEpochMS: Int64
    private var sources: [String: RuntimeHealthSnapshot.SourceState] = [:]
    private var latestMonotonicNS: [String: UInt64] = [:]

    public init(
        fileURL: URL,
        generationID: UUID = UUID(),
        processID: Int = Int(ProcessInfo.processInfo.processIdentifier),
        startedAt: Date = Date()
    ) throws {
        self.fileURL = fileURL
        self.generationID = generationID
        self.processID = processID
        self.startedAtEpochMS = Int64(startedAt.timeIntervalSince1970 * 1_000)
        encoder.outputFormatting = [.sortedKeys]

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try persist(updatedAt: startedAt)
    }

    /// Returns false when the semantic state is unchanged, avoiding disk work
    /// for repeated health observations carrying only new measurement detail.
    @discardableResult
    public func update(source: String, state: String, monotonicNS: UInt64, at date: Date = Date()) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let latest = latestMonotonicNS[source], monotonicNS <= latest { return false }
        if sources[source]?.state == state {
            latestMonotonicNS[source] = monotonicNS
            return false
        }
        let previousLatest = latestMonotonicNS[source]
        let previousState = sources[source]
        latestMonotonicNS[source] = monotonicNS
        sources[source] = .init(state: state, monotonicNS: monotonicNS)
        do {
            try persist(updatedAt: date)
        } catch {
            latestMonotonicNS[source] = previousLatest
            sources[source] = previousState
            throw error
        }
        return true
    }

    private func persist(updatedAt: Date) throws {
        let snapshot = RuntimeHealthSnapshot(
            generationID: generationID,
            processID: processID,
            startedAtEpochMS: startedAtEpochMS,
            updatedAtEpochMS: Int64(updatedAt.timeIntervalSince1970 * 1_000),
            sources: sources
        )
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
