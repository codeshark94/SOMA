import CryptoKit
import Darwin
import Foundation

public enum HermesAgentTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingForInput = "waiting_for_input"
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public struct HermesAgentTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let goalEpisodeID: UUID
    public let parentTaskID: UUID?
    public let title: String
    public let objective: String
    public let workingDirectory: String
    public let status: HermesAgentTaskStatus
    public let hermesStoredSessionID: String?
    public let result: String?
    public let error: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let reportedAt: Date?

    public init(
        id: UUID = UUID(),
        goalEpisodeID: UUID,
        parentTaskID: UUID? = nil,
        title: String,
        objective: String,
        workingDirectory: String,
        status: HermesAgentTaskStatus = .queued,
        hermesStoredSessionID: String? = nil,
        result: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        reportedAt: Date? = nil
    ) {
        self.id = id
        self.goalEpisodeID = goalEpisodeID
        self.parentTaskID = parentTaskID
        self.title = Self.bounded(title, limit: 160)
        self.objective = Self.bounded(objective, limit: 24_000)
        self.workingDirectory = Self.bounded(workingDirectory, limit: 1_024)
        self.status = status
        self.hermesStoredSessionID = hermesStoredSessionID.map { Self.bounded($0, limit: 160) }
        self.result = result.map { Self.bounded($0, limit: 96_000) }
        self.error = error.map { Self.bounded($0, limit: 2_000) }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.reportedAt = reportedAt
    }

    public func updating(
        status: HermesAgentTaskStatus? = nil,
        hermesStoredSessionID: String?? = nil,
        result: String?? = nil,
        error: String?? = nil,
        completedAt: Date?? = nil,
        reportedAt: Date?? = nil,
        at date: Date = Date()
    ) -> Self {
        Self(
            id: id,
            goalEpisodeID: goalEpisodeID,
            parentTaskID: parentTaskID,
            title: title,
            objective: objective,
            workingDirectory: workingDirectory,
            status: status ?? self.status,
            hermesStoredSessionID: hermesStoredSessionID ?? self.hermesStoredSessionID,
            result: result ?? self.result,
            error: error ?? self.error,
            createdAt: createdAt,
            updatedAt: date,
            completedAt: completedAt ?? self.completedAt,
            reportedAt: reportedAt ?? self.reportedAt
        )
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

public enum HermesAgentTaskOperation: String, Codable, Sendable {
    case submit
    case continueTask = "continue"
    case get
    case list
    case cancel
    case markReported = "mark_reported"
}

public struct HermesAgentTaskIPCRequest: Codable, Equatable, Sendable {
    public let operation: HermesAgentTaskOperation
    public let taskID: UUID?
    public let goalEpisodeID: UUID?
    public let title: String?
    public let objective: String?
    public let workingDirectory: String?
    public let statuses: [HermesAgentTaskStatus]?

    public init(
        operation: HermesAgentTaskOperation,
        taskID: UUID? = nil,
        goalEpisodeID: UUID? = nil,
        title: String? = nil,
        objective: String? = nil,
        workingDirectory: String? = nil,
        statuses: [HermesAgentTaskStatus]? = nil
    ) {
        self.operation = operation
        self.taskID = taskID
        self.goalEpisodeID = goalEpisodeID
        self.title = title.map { String($0.prefix(160)) }
        self.objective = objective.map { String($0.prefix(24_000)) }
        self.workingDirectory = workingDirectory.map { String($0.prefix(1_024)) }
        self.statuses = statuses.map { Array($0.prefix(HermesAgentTaskStatus.allCases.count)) }
    }
}

public struct HermesAgentTaskIPCResult: Codable, Equatable, Sendable {
    public let task: HermesAgentTask?
    public let tasks: [HermesAgentTask]
    public let deduplicated: Bool

    public init(task: HermesAgentTask? = nil, tasks: [HermesAgentTask] = [], deduplicated: Bool = false) {
        self.task = task
        self.tasks = Array(tasks.prefix(100))
        self.deduplicated = deduplicated
    }
}

public enum HermesAgentTaskStoreError: Error, LocalizedError {
    case corruptStore

    public var errorDescription: String? { "The encrypted Hermes task store is corrupt" }
}

private struct HermesAgentTaskStoreEnvelope: Codable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let algorithm: String
    let ciphertext: String
}

private struct HermesAgentTaskStorePayload: Codable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let tasks: [HermesAgentTask]
}

/// Small bounded checkpoint for external work. It is intentionally separate
/// from cognitive memory because task output may contain working data that is
/// not suitable for autobiographical recall.
public final class HermesAgentTaskStore: @unchecked Sendable {
    public static let checkpointFilename = "hermes-agent-tasks.encjson"

    private let lock = NSLock()
    private let checkpointURL: URL
    private let key: SymmetricKey
    private let maximumTasks: Int

    public init(
        directoryURL: URL,
        encryptionKey: CognitiveMemoryEncryptionKey,
        maximumTasks: Int = 100
    ) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        checkpointURL = directoryURL.appendingPathComponent(Self.checkpointFilename)
        key = SymmetricKey(data: encryptionKey.rawRepresentation)
        self.maximumTasks = max(8, maximumTasks)
    }

    public func load() throws -> [HermesAgentTask] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: checkpointURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(HermesAgentTaskStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == HermesAgentTaskStoreEnvelope.schemaVersion,
                  envelope.algorithm == "AES.GCM.256",
                  let combined = Data(base64Encoded: envelope.ciphertext) else {
                throw HermesAgentTaskStoreError.corruptStore
            }
            let plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined),
                using: key
            )
            let payload = try decoder.decode(HermesAgentTaskStorePayload.self, from: plaintext)
            guard payload.schemaVersion == HermesAgentTaskStorePayload.schemaVersion else {
                throw HermesAgentTaskStoreError.corruptStore
            }
            return Array(payload.tasks.suffix(maximumTasks))
        } catch let error as HermesAgentTaskStoreError {
            throw error
        } catch {
            throw HermesAgentTaskStoreError.corruptStore
        }
    }

    public func save(_ tasks: [HermesAgentTask]) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payload = HermesAgentTaskStorePayload(
            schemaVersion: HermesAgentTaskStorePayload.schemaVersion,
            tasks: Array(tasks.suffix(maximumTasks))
        )
        let sealed = try AES.GCM.seal(try encoder.encode(payload), using: key)
        guard let combined = sealed.combined else { throw HermesAgentTaskStoreError.corruptStore }
        let envelope = HermesAgentTaskStoreEnvelope(
            schemaVersion: HermesAgentTaskStoreEnvelope.schemaVersion,
            algorithm: "AES.GCM.256",
            ciphertext: combined.base64EncodedString()
        )
        try encoder.encode(envelope).write(to: checkpointURL, options: .atomic)
        guard Darwin.chmod(checkpointURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
