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

public enum HermesAgentReportDecision: String, Codable, Equatable, Sendable {
    case accepted
    case declined
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
    public let reportOfferAt: Date?
    public let reportDecision: HermesAgentReportDecision?
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
        reportOfferAt: Date? = nil,
        reportDecision: HermesAgentReportDecision? = nil,
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
        self.reportOfferAt = reportOfferAt
        self.reportDecision = reportDecision
        self.reportedAt = reportedAt
    }

    public func updating(
        status: HermesAgentTaskStatus? = nil,
        hermesStoredSessionID: String?? = nil,
        result: String?? = nil,
        error: String?? = nil,
        completedAt: Date?? = nil,
        reportOfferAt: Date?? = nil,
        reportDecision: HermesAgentReportDecision?? = nil,
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
            reportOfferAt: reportOfferAt ?? self.reportOfferAt,
            reportDecision: reportDecision ?? self.reportDecision,
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
    case markReportOffered = "mark_report_offered"
    case resolveReportOffer = "resolve_report_offer"
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
    public let wantsReport: Bool?

    public init(
        operation: HermesAgentTaskOperation,
        taskID: UUID? = nil,
        goalEpisodeID: UUID? = nil,
        title: String? = nil,
        objective: String? = nil,
        workingDirectory: String? = nil,
        statuses: [HermesAgentTaskStatus]? = nil,
        wantsReport: Bool? = nil
    ) {
        self.operation = operation
        self.taskID = taskID
        self.goalEpisodeID = goalEpisodeID
        self.title = title.map { String($0.prefix(160)) }
        self.objective = objective.map { String($0.prefix(24_000)) }
        self.workingDirectory = workingDirectory.map { String($0.prefix(1_024)) }
        self.statuses = statuses.map { Array($0.prefix(HermesAgentTaskStatus.allCases.count)) }
        self.wantsReport = wantsReport
    }
}

public struct HermesAgentTaskIPCResult: Codable, Equatable, Sendable {
    public let task: HermesAgentTask?
    public let tasks: [HermesAgentTask]
    public let deduplicated: Bool
    public let reportDecision: HermesAgentReportDecision?
    public let reportResult: String?

    public init(
        task: HermesAgentTask? = nil,
        tasks: [HermesAgentTask] = [],
        deduplicated: Bool = false,
        reportDecision: HermesAgentReportDecision? = nil,
        reportResult: String? = nil
    ) {
        self.task = task
        self.tasks = Array(tasks.prefix(100))
        self.deduplicated = deduplicated
        self.reportDecision = reportDecision
        self.reportResult = reportResult.map { String($0.prefix(96_000)) }
    }
}

public enum HermesReportOfferPrompt {
    public static func question(languageTag: String?) -> String {
        let language = (languageTag ?? "").lowercased().split(separator: "-").first.map(String.init) ?? ""
        return switch language {
        case "ko": "맡겨 주신 작업이 끝났어요. 지금 결과를 보고드릴까요?"
        case "zh": "您交给我的任务已经完成。现在要听结果吗？"
        case "ja": "お任せいただいた作業が完了しました。今、結果をご報告しましょうか？"
        case "es": "La tarea que me encargaste ya terminó. ¿Quieres que te informe del resultado ahora?"
        case "fr": "La tâche que vous m'avez confiée est terminée. Voulez-vous le résultat maintenant ?"
        case "de": "Die beauftragte Aufgabe ist abgeschlossen. Soll ich das Ergebnis jetzt berichten?"
        case "pt": "A tarefa que você me passou terminou. Quer que eu relate o resultado agora?"
        case "it": "Il compito che mi hai affidato è terminato. Vuoi che ti riferisca il risultato ora?"
        case "ru": "Порученная задача завершена. Сообщить результат сейчас?"
        case "ar": "اكتملت المهمة التي طلبتها. هل تريد أن أبلغك بالنتيجة الآن؟"
        case "hi": "आपने जो काम सौंपा था वह पूरा हो गया है। क्या मैं अभी परिणाम बताऊँ?"
        default: "The task you asked me to handle is complete. Would you like the result now?"
        }
    }
}

public enum HermesAgentReportWorkflowError: Error, Equatable, Sendable {
    case unavailable
    case notOffered
}

public enum HermesAgentReportWorkflow {
    public static func pendingOffers(in tasks: [HermesAgentTask]) -> [HermesAgentTask] {
        tasks.filter {
            $0.status == .completed
                && $0.reportedAt == nil
                && $0.reportOfferAt == nil
        }
    }

    public static func markOffered(
        _ task: HermesAgentTask,
        at date: Date = Date()
    ) throws -> HermesAgentTask {
        guard task.status == .completed, task.reportedAt == nil else {
            throw HermesAgentReportWorkflowError.unavailable
        }
        guard task.reportOfferAt == nil else { return task }
        return task.updating(reportOfferAt: .some(date), at: date)
    }

    public static func resolve(
        _ task: HermesAgentTask,
        wantsReport: Bool,
        at date: Date = Date()
    ) throws -> (task: HermesAgentTask, result: String?) {
        guard task.status == .completed, task.reportedAt == nil else {
            throw HermesAgentReportWorkflowError.unavailable
        }
        guard task.reportOfferAt != nil else {
            throw HermesAgentReportWorkflowError.notOffered
        }
        let decision: HermesAgentReportDecision = wantsReport ? .accepted : .declined
        return (
            task.updating(
                reportDecision: .some(decision),
                reportedAt: .some(date),
                at: date
            ),
            wantsReport ? task.result : nil
        )
    }
}

public enum HermesAgentTaskDeduplication {
    /// One explicit request episode owns at most one root worker. Objective
    /// wording is model-authored and may vary across retries, so it cannot be
    /// part of the root idempotency key.
    public static func rootTask(
        for goalEpisodeID: UUID,
        in tasks: [HermesAgentTask]
    ) -> HermesAgentTask? {
        tasks.last {
            $0.goalEpisodeID == goalEpisodeID && $0.parentTaskID == nil
        }
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
