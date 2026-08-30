import Foundation
import SOMACore
import Darwin

private enum HermesAgentRunnerError: Error, LocalizedError {
    case executableUnavailable
    case launchFailed(String)
    case backendTimeout
    case malformedResponse(String)
    case rpc(String)
    case taskTimeout

    var errorDescription: String? {
        switch self {
        case .executableUnavailable: "hermes_agent_executable_unavailable"
        case let .launchFailed(message): "hermes_agent_launch_failed: \(message)"
        case .backendTimeout: "hermes_agent_backend_start_timeout"
        case let .malformedResponse(message): "hermes_agent_protocol_invalid: \(message)"
        case let .rpc(message): "hermes_agent_rpc_failed: \(message)"
        case .taskTimeout: "hermes_agent_task_timeout"
        }
    }
}

private struct HermesAgentCoordinatorError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct HermesAgentRunResult: Sendable {
    let storedSessionID: String
    let text: String
}

private final class HermesAgentProcessHandle: @unchecked Sendable {
    let process: Process
    let socket: URLSessionWebSocketTask
    private let stopLock = NSLock()
    private var stopped = false

    init(process: Process, socket: URLSessionWebSocketTask) {
        self.process = process
        self.socket = socket
    }

    func stop() {
        let shouldStop = stopLock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        socket.cancel(with: .goingAway, reason: nil)
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private enum HermesAgentProtocolRunner {
    static func run(
        task: HermesAgentTask,
        resumeStoredSessionID: String?,
        onHandle: @escaping @Sendable (HermesAgentProcessHandle) -> Void,
        onSessionOpened: @escaping @Sendable (_ storedSessionID: String) -> Void
    ) async throws -> HermesAgentRunResult {
        let runtime = try discoverRuntime()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-hermes-\(task.id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let readyURL = temporaryDirectory.appendingPathComponent("ready.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.executablePath)
        process.arguments = runtime.loopbackWorkerArguments
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_DASHBOARD_SESSION_TOKEN"] = token
        environment["HERMES_DESKTOP_READY_FILE"] = readyURL.path
        process.environment = environment
        let null = FileHandle(forWritingAtPath: "/dev/null")
        process.standardOutput = null
        process.standardError = null
        do {
            try process.run()
        } catch {
            throw HermesAgentRunnerError.launchFailed(error.localizedDescription)
        }
        defer {
            null?.closeFile()
            if process.isRunning { process.terminate() }
        }

        let port = try await waitForPort(at: readyURL, process: process)
        guard var components = URLComponents(string: "ws://127.0.0.1:\(port)/api/ws") else {
            throw HermesAgentRunnerError.malformedResponse("invalid_websocket_url")
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let endpoint = components.url else {
            throw HermesAgentRunnerError.malformedResponse("invalid_websocket_url")
        }
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 64 * 1_048_576
        socket.resume()
        let handle = HermesAgentProcessHandle(process: process, socket: socket)
        onHandle(handle)
        defer { handle.stop() }

        let session = try await openSession(
            socket: socket,
            task: task,
            profileName: runtime.profileName,
            resumeStoredSessionID: resumeStoredSessionID
        )
        onSessionOpened(session.storedID)
        let promptID = 2
        try await sendRPC(
            socket: socket,
            id: promptID,
            method: "prompt.submit",
            params: [
                "session_id": session.runtimeID,
                "text": task.objective,
            ]
        )

        var submitAccepted = false
        var workspaceAnchorRequested = false
        var workspaceAnchored = false
        var completedText: String?
        let deadline = Date().addingTimeInterval(2 * 60 * 60)
        while Date() < deadline {
            let value = try await receiveObject(socket)
            if let id = value["id"] as? Int, id == promptID {
                if let error = rpcError(value) { throw HermesAgentRunnerError.rpc(error) }
                submitAccepted = true
                try await sendRPC(
                    socket: socket,
                    id: 3,
                    method: "session.workspace.move",
                    params: [
                        "session_key": session.storedID,
                        "cwd": task.workingDirectory,
                        "profile": runtime.profileName,
                    ]
                )
                workspaceAnchorRequested = true
                continue
            }
            if let id = value["id"] as? Int, id == 3 {
                if let error = rpcError(value) { throw HermesAgentRunnerError.rpc(error) }
                workspaceAnchored = true
                if let completedText {
                    return HermesAgentRunResult(storedSessionID: session.storedID, text: completedText)
                }
                continue
            }
            guard value["method"] as? String == "event",
                  let params = value["params"] as? [String: Any],
                  params["session_id"] as? String == session.runtimeID,
                  let type = params["type"] as? String,
                  let payload = params["payload"] as? [String: Any] else { continue }
            if type == "message.complete" {
                let status = payload["status"] as? String ?? ""
                if status == "complete",
                   let text = payload["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if workspaceAnchored {
                        return HermesAgentRunResult(storedSessionID: session.storedID, text: text)
                    }
                    completedText = text
                    continue
                }
                let message = payload["error"] as? String
                    ?? payload["text"] as? String
                    ?? "message_complete_\(status)"
                throw HermesAgentRunnerError.rpc(message)
            }
            if ["approval.request", "clarify.request", "sudo.request", "secret.request"].contains(type) {
                throw HermesAgentRunnerError.rpc("worker_requires_input: \(type)")
            }
        }
        if completedText != nil, workspaceAnchorRequested, !workspaceAnchored {
            throw HermesAgentRunnerError.rpc("workspace_anchor_not_confirmed")
        }
        throw submitAccepted ? HermesAgentRunnerError.taskTimeout : HermesAgentRunnerError.rpc("prompt_not_accepted")
    }

    private static func discoverRuntime() throws -> HermesAgentRuntimeConfiguration {
        guard let runtime = HermesAgentRuntimeConfiguration.discover() else {
            throw HermesAgentRunnerError.executableUnavailable
        }
        return runtime
    }

    private static func waitForPort(at readyURL: URL, process: Process) async throws -> Int {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, process.isRunning {
            if let data = try? Data(contentsOf: readyURL),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = value["port"] as? Int,
               (1...65_535).contains(port) {
                return port
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HermesAgentRunnerError.backendTimeout
    }

    private static func openSession(
        socket: URLSessionWebSocketTask,
        task: HermesAgentTask,
        profileName: String,
        resumeStoredSessionID: String?
    ) async throws -> (runtimeID: String, storedID: String) {
        let id = 1
        if let resumeStoredSessionID {
            try await sendRPC(
                socket: socket,
                id: id,
                method: "session.resume",
                params: ["session_id": resumeStoredSessionID]
            )
        } else {
            try await sendRPC(
                socket: socket,
                id: id,
                method: "session.create",
                params: [
                    "title": task.title,
                    "cwd": task.workingDirectory,
                    "source": "soma",
                    "profile": profileName,
                    "reasoning_effort": "medium",
                ]
            )
        }
        while true {
            let value = try await receiveObject(socket)
            guard value["id"] as? Int == id else { continue }
            if let error = rpcError(value) { throw HermesAgentRunnerError.rpc(error) }
            guard let result = value["result"] as? [String: Any],
                  let runtimeID = result["session_id"] as? String else {
                throw HermesAgentRunnerError.malformedResponse("session_id_missing")
            }
            let storedID = result["stored_session_id"] as? String ?? resumeStoredSessionID
            guard let storedID, !storedID.isEmpty else {
                throw HermesAgentRunnerError.malformedResponse("stored_session_id_missing")
            }
            return (runtimeID, storedID)
        }
    }

    private static func sendRPC(
        socket: URLSessionWebSocketTask,
        id: Int,
        method: String,
        params: [String: Any]
    ) async throws {
        let value: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HermesAgentRunnerError.malformedResponse("request_encoding")
        }
        try await socket.send(.string(text))
    }

    private static func receiveObject(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(value): data = value
        @unknown default: throw HermesAgentRunnerError.malformedResponse("unknown_frame")
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesAgentRunnerError.malformedResponse("json_object_expected")
        }
        return value
    }

    private static func rpcError(_ value: [String: Any]) -> String? {
        guard let error = value["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? String(describing: error)
    }
}

final class HermesAgentTaskCoordinator: @unchecked Sendable {
    typealias CompletionHandler = @Sendable (HermesAgentTask) -> Void
    typealias HealthHandler = @Sendable (_ state: String, _ message: String?) -> Void

    private let queue = DispatchQueue(label: "soma.hermes.agent.tasks", qos: .utility)
    private let store: HermesAgentTaskStore
    private let enabled: Bool
    private let defaultWorkingDirectory: String
    private let onCompletion: CompletionHandler
    private let onHealth: HealthHandler
    private var tasks: [HermesAgentTask]
    private var activeTaskID: UUID?
    private var activeHandle: HermesAgentProcessHandle?

    init(
        store: HermesAgentTaskStore,
        enabled: Bool,
        defaultWorkingDirectory: String,
        onCompletion: @escaping CompletionHandler,
        onHealth: @escaping HealthHandler
    ) throws {
        self.store = store
        self.enabled = enabled
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.onCompletion = onCompletion
        self.onHealth = onHealth
        let now = Date()
        tasks = try store.load().map { task in
            guard task.status == .running else { return task }
            return task.updating(
                status: .queued,
                error: .some("resuming_after_runtime_restart"),
                at: now
            )
        }
        try store.save(tasks)
        onHealth(
            enabled ? "ready" : "disabled",
            enabled ? "queued=\(tasks.filter { $0.status == .queued }.count)" : nil
        )
        queue.async { [weak self] in self?.startNextIfNeeded() }
    }

    func handle(_ request: HermesAgentTaskIPCRequest) -> Result<HermesAgentTaskIPCResult, Error> {
        queue.sync {
            do {
                guard enabled else { throw HermesAgentCoordinatorError(message: "hermes_agent_delegation_disabled") }
                switch request.operation {
                case .submit:
                    guard let goalEpisodeID = request.goalEpisodeID,
                          let objective = normalized(request.objective, limit: 24_000),
                          let title = normalized(request.title, limit: 160) else {
                        throw HermesAgentCoordinatorError(message: "hermes_task_request_invalid")
                    }
                    if let existing = HermesAgentTaskDeduplication.rootTask(
                        for: goalEpisodeID,
                        in: tasks
                    ) {
                        return .success(.init(task: existing, deduplicated: true))
                    }
                    let directory = try validatedDirectory(request.workingDirectory)
                    let task = HermesAgentTask(
                        goalEpisodeID: goalEpisodeID,
                        title: title,
                        objective: objective,
                        workingDirectory: directory
                    )
                    tasks.append(task)
                    try persist()
                    startNextIfNeeded()
                    return .success(.init(task: task))
                case .continueTask:
                    guard let parentID = request.taskID,
                          let parent = tasks.first(where: { $0.id == parentID }),
                          (parent.status.isTerminal || parent.status == .waitingForInput),
                          parent.hermesStoredSessionID != nil,
                          let objective = normalized(request.objective, limit: 24_000) else {
                        throw HermesAgentCoordinatorError(message: "hermes_task_continuation_invalid")
                    }
                    let goal = request.goalEpisodeID ?? parent.goalEpisodeID
                    if let existing = tasks.last(where: {
                        $0.goalEpisodeID == goal && $0.parentTaskID == parentID && $0.objective == objective
                    }) {
                        return .success(.init(task: existing, deduplicated: true))
                    }
                    let task = HermesAgentTask(
                        goalEpisodeID: goal,
                        parentTaskID: parentID,
                        title: normalized(request.title, limit: 160) ?? parent.title,
                        objective: objective,
                        workingDirectory: parent.workingDirectory,
                        hermesStoredSessionID: parent.hermesStoredSessionID
                    )
                    tasks.append(task)
                    try persist()
                    startNextIfNeeded()
                    return .success(.init(task: task))
                case .get:
                    guard let taskID = request.taskID,
                          let task = tasks.first(where: { $0.id == taskID }) else {
                        throw HermesAgentCoordinatorError(message: "hermes_task_unknown")
                    }
                    return .success(.init(task: task))
                case .list:
                    let statusSet = request.statuses.map(Set.init)
                    let values = tasks.reversed().filter { statusSet?.contains($0.status) ?? true }
                    return .success(.init(tasks: Array(values.prefix(100))))
                case .cancel:
                    guard let taskID = request.taskID,
                          let index = tasks.firstIndex(where: { $0.id == taskID }),
                          !tasks[index].status.isTerminal else {
                        throw HermesAgentCoordinatorError(message: "hermes_task_not_cancellable")
                    }
                    tasks[index] = tasks[index].updating(
                        status: .cancelled,
                        error: .some("cancelled_by_administrator"),
                        completedAt: .some(Date())
                    )
                    if activeTaskID == taskID {
                        activeHandle?.stop()
                        activeHandle = nil
                        activeTaskID = nil
                    }
                    try persist()
                    startNextIfNeeded()
                    return .success(.init(task: tasks[index]))
                case .markReportOffered:
                    guard let taskID = request.taskID,
                          let index = tasks.firstIndex(where: { $0.id == taskID }) else {
                        throw HermesAgentCoordinatorError(message: "hermes_report_offer_invalid")
                    }
                    tasks[index] = try HermesAgentReportWorkflow.markOffered(tasks[index])
                    try persist()
                    return .success(.init(task: tasks[index]))
                case .resolveReportOffer:
                    guard let taskID = request.taskID,
                          let wantsReport = request.wantsReport,
                          let index = tasks.firstIndex(where: { $0.id == taskID }) else {
                        throw HermesAgentCoordinatorError(message: "hermes_report_offer_resolution_invalid")
                    }
                    let resolution = try HermesAgentReportWorkflow.resolve(
                        tasks[index],
                        wantsReport: wantsReport
                    )
                    tasks[index] = resolution.task
                    try persist()
                    return .success(.init(
                        reportDecision: resolution.task.reportDecision,
                        reportResult: resolution.result
                    ))
                case .markReported:
                    guard let taskID = request.taskID,
                          let index = tasks.firstIndex(where: { $0.id == taskID }),
                          tasks[index].status == .completed else {
                        throw HermesAgentCoordinatorError(message: "hermes_task_not_reportable")
                    }
                    tasks[index] = tasks[index].updating(reportedAt: .some(Date()))
                    try persist()
                    return .success(.init(task: tasks[index]))
                }
            } catch {
                return .failure(error)
            }
        }
    }

    func pendingReportOffers() -> [HermesAgentTask] {
        queue.sync {
            Array(HermesAgentReportWorkflow.pendingOffers(in: Array(tasks.reversed())).prefix(8))
        }
    }

    func stop() {
        queue.sync {
            activeHandle?.stop()
            activeHandle = nil
            activeTaskID = nil
        }
    }

    private func startNextIfNeeded() {
        guard enabled, activeTaskID == nil,
              let index = tasks.firstIndex(where: { $0.status == .queued }) else { return }
        let task = tasks[index]
        tasks[index] = task.updating(status: .running, error: .some(nil))
        activeTaskID = task.id
        try? persist()
        onHealth("running", "task_id=\(task.id.uuidString.lowercased())")
        let resumeID = task.hermesStoredSessionID
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await HermesAgentProtocolRunner.run(
                    task: task,
                    resumeStoredSessionID: resumeID,
                    onHandle: { [weak self] handle in self?.accept(handle, for: task.id) },
                    onSessionOpened: { [weak self] storedID in
                        self?.recordSession(storedID, for: task.id)
                    }
                )
                self?.finish(taskID: task.id, result: .success(result))
            } catch {
                self?.finish(taskID: task.id, result: .failure(error))
            }
        }
    }

    private func accept(_ handle: HermesAgentProcessHandle, for taskID: UUID) {
        queue.async { [weak self] in
            guard let self, activeTaskID == taskID else {
                handle.stop()
                return
            }
            activeHandle = handle
        }
    }

    private func recordSession(_ storedID: String, for taskID: UUID) {
        queue.async { [weak self] in
            guard let self,
                  let index = tasks.firstIndex(where: { $0.id == taskID }),
                  !tasks[index].status.isTerminal else { return }
            tasks[index] = tasks[index].updating(
                hermesStoredSessionID: .some(storedID)
            )
            try? persist()
        }
    }

    private func finish(taskID: UUID, result: Result<HermesAgentRunResult, Error>) {
        queue.async { [weak self] in
            guard let self,
                  let index = tasks.firstIndex(where: { $0.id == taskID }),
                  tasks[index].status != .cancelled else { return }
            let now = Date()
            switch result {
            case let .success(output):
                tasks[index] = tasks[index].updating(
                    status: .completed,
                    hermesStoredSessionID: .some(output.storedSessionID),
                    result: .some(output.text),
                    error: .some(nil),
                    completedAt: .some(now),
                    at: now
                )
            case let .failure(error):
                let message = error.localizedDescription
                let waiting = message.contains("worker_requires_input")
                tasks[index] = tasks[index].updating(
                    status: waiting ? .waitingForInput : .failed,
                    error: .some(message),
                    completedAt: waiting ? nil : .some(now),
                    at: now
                )
            }
            activeHandle = nil
            activeTaskID = nil
            try? persist()
            let completed = tasks[index]
            onHealth(completed.status.rawValue, "task_id=\(taskID.uuidString.lowercased())")
            if completed.status == .completed { onCompletion(completed) }
            startNextIfNeeded()
        }
    }

    private func persist() throws {
        tasks = Array(tasks.suffix(100))
        try store.save(tasks)
    }

    private func normalized(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    private func validatedDirectory(_ value: String?) throws -> String {
        let candidate = normalized(value, limit: 1_024) ?? defaultWorkingDirectory
        var isDirectory: ObjCBool = false
        guard candidate.hasPrefix("/"),
              FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HermesAgentCoordinatorError(message: "hermes_task_working_directory_invalid")
        }
        return URL(fileURLWithPath: candidate).standardizedFileURL.path
    }
}

func testHermesAgentProtocolBridge() async throws -> String {
    let task = HermesAgentTask(
        goalEpisodeID: UUID(),
        title: "SOMA Hermes bridge smoke test",
        objective: "Return exactly SOMA_HERMES_BRIDGE_OK and do not call tools.",
        workingDirectory: FileManager.default.currentDirectoryPath
    )
    final class HandleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HermesAgentProcessHandle?
        func set(_ value: HermesAgentProcessHandle) { lock.withLock { self.value = value } }
        func stop() { lock.withLock { value?.stop(); value = nil } }
    }
    let handle = HandleBox()
    defer { handle.stop() }
    let result = try await HermesAgentProtocolRunner.run(
        task: task,
        resumeStoredSessionID: nil,
        onHandle: { handle.set($0) },
        onSessionOpened: { _ in }
    )
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
}
