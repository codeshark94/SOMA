import AppKit
import Foundation
import SOMACore
import WebKit

private struct Command: Decodable {
    enum Kind: String, Decodable {
        case start
        case appendAudio = "append_audio"
        case appendOpeningAudio = "append_opening_audio"
        case appendImage = "append_image"
        case appendText = "append_text"
        case acceptExternalWork = "accept_external_work"
        case appendInstruction = "append_instruction"
        case beginVisualTurn = "begin_visual_turn"
        case stop
    }

    let type: Kind
    let initialContext: String?
    let preferredLanguageTag: String?
    let languageStartInstruction: String?
    let proactiveOpeningText: String?
    let interactionAuthority: String?
    let personContextReference: String?
    let sessionCapability: String?
    let embodimentSocketPath: String?
    let appServerURL: String?
    let cameraContextAutoInjected: Bool?
    let codexSandbox: String?
    let codexAdminOnly: Bool?
    let hermesAgentDelegationEnabled: Bool?
    let data: String?
    let sampleRate: Int?
    let samplesPerChannel: Int?
    let itemID: String?
    let taskID: String?
    let tool: String?
}

private enum FinalizedTranscriptOrigin: Equatable {
    case realtimeWire
    case appServer
}

private final class JSONLineEmitter: @unchecked Sendable {
    private let lock = NSLock()

    func emit(_ event: String, fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        lock.unlock()
    }
}

private struct JSONDictionary: @unchecked Sendable {
    let value: [String: Any]
}

private final class AppServerConnection: @unchecked Sendable {
    typealias ResponseHandler = @Sendable (JSONDictionary) -> Void
    typealias NotificationHandler = @Sendable (String, JSONDictionary) -> Void

    private let queue = DispatchQueue(label: "soma.live-voice.app-server")
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private var persistentWebSocket: URLSessionWebSocketTask?
    private var buffer = Data()
    private var nextRequestID = 1
    private var handlers: [Int: ResponseHandler] = [:]
    private let notificationHandler: NotificationHandler

    init(notificationHandler: @escaping NotificationHandler) {
        self.notificationHandler = notificationHandler
    }

    func start(
        codexURL: URL,
        sessionCapability: String?,
        appServerURL: String?,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.process.executableURL = codexURL
            if let persistentEndpoint = Self.validPersistentAppServerURL(appServerURL) {
                let socket = URLSession.shared.webSocketTask(with: persistentEndpoint)
                socket.maximumMessageSize = 64 * 1024 * 1024
                self.persistentWebSocket = socket
                socket.resume()
                self.receivePersistentWebSocket()
                self.initialize(completion: completion)
                return
            }
            var arguments = ["app-server", "--stdio", "--enable", "realtime_conversation"]
            if let token = Self.validSessionCapability(sessionCapability) {
                // The config override targets the named server while the
                // inherited environment also covers delayed MCP child launch.
                var environment = ProcessInfo.processInfo.environment
                environment["SOMA_SESSION_TOKEN"] = token
                self.process.environment = environment
                arguments += [
                    "--config",
                    "mcp_servers.soma_embodiment.env={SOMA_SESSION_TOKEN=\"\(token)\"}",
                ]
            }
            self.process.arguments = arguments
            self.process.standardInput = self.inputPipe
            self.process.standardOutput = self.outputPipe
            self.process.standardError = self.errorPipe
            self.outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let connection = self else { return }
                connection.queue.async { connection.consume(data) }
            }
            self.errorPipe.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
            do {
                try self.process.run()
                self.initialize(completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func request(
        method: String,
        params: [String: Any],
        timeoutMilliseconds: Int? = nil,
        completion: @escaping ResponseHandler
    ) {
        let sendableParams = JSONDictionary(value: params)
        queue.async {
            let requestID = self.nextRequestID
            self.nextRequestID += 1
            self.handlers[requestID] = completion
            self.write([
                "id": requestID,
                "method": method,
                "params": sendableParams.value,
            ])
            if let timeoutMilliseconds, timeoutMilliseconds > 0 {
                self.queue.asyncAfter(
                    deadline: .now() + .milliseconds(timeoutMilliseconds)
                ) {
                    guard let handler = self.handlers.removeValue(forKey: requestID) else { return }
                    handler(JSONDictionary(value: [
                        "error": [
                            "code": "request_timed_out",
                            "message": "\(method) timed out",
                        ],
                    ]))
                }
            }
        }
    }

    func stop() {
        queue.sync {
            handlers.removeAll()
            if let persistentWebSocket {
                persistentWebSocket.cancel(with: .goingAway, reason: nil)
                self.persistentWebSocket = nil
                return
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
    }

    static func responseMessage(_ response: [String: Any]) -> String {
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(256))
        }
        return "request_failed"
    }

    static func responseTimedOut(_ response: [String: Any]) -> Bool {
        guard let error = response["error"] as? [String: Any] else { return false }
        return error["code"] as? String == "request_timed_out"
    }

    private static func validSessionCapability(_ value: String?) -> String? {
        guard let value,
              value.count == 36,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            return nil
        }
        return value.lowercased()
    }

    private static func validPersistentAppServerURL(_ value: String?) -> URL? {
        guard let value,
              value.count <= 1_024,
              !value.contains("\n"),
              !value.contains("\0"),
              let url = URL(string: value),
              url.scheme == "ws",
              url.host == "127.0.0.1",
              url.port != nil else {
            return nil
        }
        return url
    }

    private func initialize(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "soma-live-voice",
                    "title": "SOMA Live Voice",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                ],
            ]
        ) { response in
            guard response.value["error"] == nil else {
                completion(.failure(LiveVoiceError.appServerResponse(Self.responseMessage(response.value))))
                return
            }
            self.notify(method: "initialized", params: [:])
            completion(.success(()))
        }
    }

    private func receivePersistentWebSocket() {
        guard let persistentWebSocket else { return }
        persistentWebSocket.receive { [weak self, weak persistentWebSocket] result in
            guard let self, let persistentWebSocket else { return }
            self.queue.async {
                guard self.persistentWebSocket === persistentWebSocket else { return }
                switch result {
                case let .success(message):
                    let data: Data
                    switch message {
                    case let .string(value): data = Data(value.utf8)
                    case let .data(value): data = value
                    @unknown default: return
                    }
                    self.consume(data.last == 0x0A ? data : data + Data([0x0A]))
                    self.receivePersistentWebSocket()
                case .failure:
                    self.persistentWebSocket = nil
                }
            }
        }
    }

    private func notify(method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        if let persistentWebSocket,
           let text = String(data: data, encoding: .utf8) {
            persistentWebSocket.send(.string(text)) { _ in }
            return
        }
        inputPipe.fileHandleForWriting.write(data)
        inputPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else { continue }
            if let requestID = message["id"] as? Int,
               let handler = handlers.removeValue(forKey: requestID) {
                handler(JSONDictionary(value: message))
                continue
            }
            if let method = message["method"] as? String {
                notificationHandler(
                    method,
                    JSONDictionary(value: message["params"] as? [String: Any] ?? [:])
                )
            }
        }
    }
}

private enum LiveVoiceError: LocalizedError {
    case codexNotFound
    case invalidCommand
    case appServerResponse(String)
    case webRTC(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "codex_app_server_not_found"
        case .invalidCommand:
            return "invalid_control_command"
        case let .appServerResponse(message):
            return "app_server: \(message)"
        case let .webRTC(message):
            return "webrtc: \(String(message.prefix(256)))"
        }
    }
}

private struct AssistantPCMChunk {
    let data: Data
    let encoded: String
    let sampleRate: Int
    let channels: Int
    let samplesPerChannel: Int
    let source: LiveVoicePlaybackReferenceSource

}

private enum VisualTurnTransportPolicy {
    static let captureTimeoutMilliseconds = 5_000
    static let evidenceInjectionTimeoutMilliseconds = 3_000
    static let cancellationTimeoutMilliseconds = 3_000
    static let replacementPresentationTimeoutMilliseconds = 12_000
}

@MainActor
private final class LiveVoiceRuntime: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private let emitter: JSONLineEmitter
    private let workingDirectory: String
    private let voice: String
    private let voiceMode: SOMARealtimeVoiceMode
    private let preferredOutputDeviceUID: String?
    private var selectedAudioOutput: SelectedAudioOutput?
    private var connection: AppServerConnection!
    private var webView: WKWebView!
    private var window: NSWindow!
    private var threadID: String?
    private var initialContext = ""
    private var preferredLanguageTag: String?
    private var languageStartInstruction: String?
    private var proactiveOpeningText: String?
    private var isProactiveSession = false
    private var pendingHermesReportTaskID: String?
    private var audioPlayoutSource: LiveVoicePlaybackReferenceSource?
    private var interactionAuthority: String?
    private var personContextReference: UUID?
    private var sessionCapability: String?
    private var embodimentSocketURL: URL?
    private var appServerURL: String?
    private var cameraContextAutoInjected = false
    private var codexSandbox = "danger-full-access"
    private var codexAdminOnly = false
    private var hermesAgentDelegationEnabled = false
    private var pendingCommands: [Command] = []
    private var webViewReady = false
    private var stopping = false
    private var startRequestAccepted = false
    private var appServerStarted = false
    private var embodimentMCPAvailable = false
    private var embodimentMCPVerificationFinished = false
    private var embodimentBodyCheckFinished = false
    private var embodimentBodyCheckAvailable = false
    private var embodimentBodyCheckFailureReason: String?
    private var personContextCheckFinished = false
    private var personContextAvailable = false
    private var webRTCStarted = false
    private var pendingOfferSDP: String?
    private var realtimeStartRequested = false
    private var webRTCConnected = false
    private var realtimeSessionInitialized = false
    private var activeEmitted = false
    private var inputSpeechInProgress = false
    private var partialUserTranscript = ""
    private var assistantOutputActive = false
    private var assistantOutputEndWorkItem: DispatchWorkItem?
    private var embodimentMCPVerificationTimeoutWorkItem: DispatchWorkItem?
    private var pendingTransportClosureReason: String?
    private var assistantSpeechObservedSequences: Set<UInt64> = []
    private var reportedEmbodimentMCPItemIDs: Set<String> = []
    private var cognitiveTurnOpen = false
    private var naturalTurnTakingConfirmed = false
    private var currentRealtimeResponseID: String?
    private var visualResponseBarrier: LiveVoiceVisualResponseBarrier?
    private var visualEvidenceInjectionInFlightEpisodeID: UUID?
    private var deferredVisualEvidenceEpisodeID: UUID?
    private var visualCancellationTimeoutWorkItem: DispatchWorkItem?
    private var visualReplacementTimeoutWorkItem: DispatchWorkItem?
    private var participantTurnSequence: UInt64 = 0
    private var participantAudioEpoch: UInt64 = 0
    private var latestParticipantTranscript = ""
    private var lastWireParticipantTranscript: (text: String, turnID: String?, epoch: UInt64)?
    private var currentBackingTurnID: String?
    private var backingTurnSequenceByID: [String: UInt64] = [:]
    private var pendingBackingTurnHydrationIDs: Set<String> = []
    private var handledBackingTurnIDs: Set<String> = []
    private var handledBackingTurnOrder: [String] = []
    private var managedResponseInFlightSequences: Set<UInt64> = []
    private var managedResponseDeliveredSequences: Set<UInt64> = []
    private var responseDeadlineWorkItem: DispatchWorkItem?
    private var responseDeadlineSequence: UInt64?
    private var externalWorkResponseOwnerSequence: UInt64?
    private var observedRealtimeEventTypes: Set<String> = []
    private var finalizedTranscriptItemIDs: Set<String> = []
    private var finalizedTranscriptItemOrder: [String] = []
    private var lastFallbackTranscript: (role: String, text: String, atNS: UInt64)?
    private let preflightGoalEpisodeID = UUID()
    private let conversationControlClassifier = LiveVoiceConversationControlClassifier()

    init(
        emitter: JSONLineEmitter,
        workingDirectory: String,
        voice: String,
        voiceMode: SOMARealtimeVoiceMode,
        preferredOutputDeviceUID: String?
    ) {
        self.emitter = emitter
        self.workingDirectory = workingDirectory
        self.voice = voice
        self.voiceMode = voiceMode
        self.preferredOutputDeviceUID = preferredOutputDeviceUID
        super.init()
        connection = AppServerConnection { [weak self] method, params in
            DispatchQueue.main.async {
                self?.handleNotification(method: method, params: params.value)
            }
        }
    }

    func prepare() {
        do {
            let renderedPCMHandler: (@Sendable (SelectedAudioOutput.RenderedPCM) -> Void)?
            if voiceMode.requiresProcessedPlayback {
                renderedPCMHandler = { [weak self] rendered in
                    Task { @MainActor [weak self] in
                        self?.forwardRenderedAssistantReference(rendered)
                    }
                }
            } else {
                renderedPCMHandler = nil
            }
            let output = try SelectedAudioOutput(
                preferredUID: preferredOutputDeviceUID,
                voiceMode: voiceMode,
                renderedPCMHandler: renderedPCMHandler,
                playoutStatusHandler: { [weak self] status in
                    var fields: [String: Any] = [
                        "state": status.state,
                        "sample_rate": status.sampleRate,
                        "num_channels": status.channels,
                        "chunk_duration_ms": status.chunkDurationMilliseconds,
                        "queued_ms": status.queuedDurationMilliseconds,
                        "underruns": status.underruns,
                    ]
                    if let arrivalGapMilliseconds = status.arrivalGapMilliseconds {
                        fields["arrival_gap_ms"] = arrivalGapMilliseconds
                    }
                    self?.emitter.emit("audio_playout_status", fields: fields)
                }
            )
            selectedAudioOutput = output
            emitter.emit("audio_output_selected", fields: [
                "name": output.selectedName,
                "uid": output.selectedUID ?? "unknown",
                "route": output.resolution,
                "voice_mode": voiceMode.rawValue,
            ])
        } catch {
            emitter.emit("failed", fields: [
                "reason": String(error.localizedDescription.prefix(256)),
            ])
            NSApplication.shared.terminate(nil)
            return
        }
        let controller = WKUserContentController()
        controller.add(self, name: "soma")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 2, height: 2),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        webView.loadHTMLString(Self.webRTCHTML, baseURL: URL(string: "https://localhost/"))
    }

    func receive(_ command: Command) {
        if !webViewReady {
            switch command.type {
            case .start:
                // App Server connection and thread creation do not depend on
                // WebKit. Start them while the hidden audio frontend loads;
                // the WebRTC offer is joined once both sides are ready.
                break
            case .appendAudio, .appendOpeningAudio, .appendImage, .appendText, .acceptExternalWork,
                 .appendInstruction,
                 .beginVisualTurn, .stop:
                pendingCommands.append(command)
                return
            }
        }
        switch command.type {
        case .start:
            guard threadID == nil else { return }
            initialContext = String((command.initialContext ?? "").prefix(24_000))
            preferredLanguageTag = (command.preferredLanguageTag ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            languageStartInstruction = (command.languageStartInstruction ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            proactiveOpeningText = (command.proactiveOpeningText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            isProactiveSession = proactiveOpeningText?.isEmpty == false
            interactionAuthority = (command.interactionAuthority ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawPersonContextReference = command.personContextReference ?? ""
            personContextReference = UUID(
                uuidString: rawPersonContextReference.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            sessionCapability = (command.sessionCapability ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let socketPath = (command.embodimentSocketPath ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            embodimentSocketURL = socketPath.hasPrefix("/")
                ? URL(fileURLWithPath: socketPath)
                : nil
            appServerURL = command.appServerURL?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cameraContextAutoInjected = command.cameraContextAutoInjected ?? false
            if let sandbox = command.codexSandbox,
               ["read-only", "workspace-write", "danger-full-access"].contains(sandbox) {
                codexSandbox = sandbox
            }
            codexAdminOnly = command.codexAdminOnly ?? false
            hermesAgentDelegationEnabled = command.hermesAgentDelegationEnabled ?? false
            audioPlayoutSource = nil
            startAppServer()
        case .appendImage:
            guard let threadID,
                  let dataURI = command.data,
                  dataURI.utf8.count <= 4 * 1_048_576,
                  Self.validCameraImageDataURI(dataURI) else { return }
            injectCameraImage(dataURI, into: threadID)
        case .appendAudio:
            guard threadID != nil,
                  let data = command.data,
                  data.count <= 262_144,
                  let sampleRate = command.sampleRate,
                  (8_000...96_000).contains(sampleRate),
                  let samplesPerChannel = command.samplesPerChannel,
                  (1...16_384).contains(samplesPerChannel) else { return }
            guard let encoded = try? JSONEncoder().encode(data),
                  let literal = String(data: encoded, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "appendPCM16(\(literal), \(sampleRate), \(samplesPerChannel))"
            ) { [weak self] _, error in
                if let error { self?.fail(LiveVoiceError.webRTC(error.localizedDescription)) }
            }
        case .appendOpeningAudio:
            guard threadID != nil,
                  let data = command.data,
                  data.utf8.count <= 4 * 1_048_576,
                  let sampleRate = command.sampleRate,
                  (8_000...96_000).contains(sampleRate),
                  let samplesPerChannel = command.samplesPerChannel,
                  (1...1_500_000).contains(samplesPerChannel),
                  let itemID = command.itemID,
                  UUID(uuidString: itemID) != nil,
                  let decoded = Data(base64Encoded: data),
                  decoded.count == samplesPerChannel * MemoryLayout<Int16>.size else {
                emitter.emit("opening_audio_rejected", fields: [
                    "reason": "invalid_opening_audio_payload",
                ])
                return
            }
            guard let encoded = try? JSONEncoder().encode(data),
                  let literal = String(data: encoded, encoding: .utf8),
                  let encodedItemID = try? JSONEncoder().encode(itemID),
                  let itemLiteral = String(data: encodedItemID, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "appendPCM16(\(literal), \(sampleRate), \(samplesPerChannel), \(itemLiteral))"
            ) { [weak self] result, error in
                guard let self, !self.stopping else { return }
                guard error == nil, (result as? Bool) == true else {
                    self.emitter.emit("opening_audio_rejected", fields: [
                        "item_id": itemID,
                        "reason": error?.localizedDescription ?? "webrtc_input_track_unavailable",
                    ])
                    return
                }
                self.emitter.emit("opening_audio_queued", fields: [
                    "item_id": itemID,
                    "sample_rate": sampleRate,
                    "samples_per_channel": samplesPerChannel,
                ])
            }
        case .appendText:
            guard let threadID,
                  let text = command.data?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text.utf8.count <= 96_000,
                  let taskID = command.taskID,
                  UUID(uuidString: taskID) != nil else { return }
            connection.request(
                method: "thread/realtime/appendText",
                params: [
                    "threadId": threadID,
                    "text": text,
                    "role": "user",
                ]
            ) { [weak self] response in
                guard response.value["error"] == nil else {
                    DispatchQueue.main.async {
                        self?.emitter.emit("hermes_task_result_rejected", fields: [
                            "task_id": taskID,
                            "reason": AppServerConnection.responseMessage(response.value),
                        ])
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingHermesReportTaskID = taskID
                }
            }
        case .acceptExternalWork:
            guard let text = command.data?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text.utf8.count <= 8_192,
                  let taskID = command.taskID,
                  UUID(uuidString: taskID) != nil else { return }
            externalWorkResponseOwnerSequence = participantTurnSequence
            interruptBackingTurnIfOwnedByExternalWork()
            appendManagedHandoffSpeech(
                text,
                sequence: participantTurnSequence,
                kind: "external_work_ack",
                taskID: taskID,
                successEvent: "hermes_delegation_ack_spoken",
                failureEvent: "hermes_delegation_ack_rejected"
            )
        case .appendInstruction:
            guard let threadID,
                  let text = command.data?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text.utf8.count <= 8_192,
                  let turnID = command.taskID,
                  UUID(uuidString: turnID) != nil,
                  let tool = command.tool,
                  L2CognitiveToolPolicy.knownToolNames.contains(tool) else { return }
            let item: [String: Any] = [
                "type": "message",
                "role": "developer",
                "content": [["type": "input_text", "text": text]],
            ]
            connection.request(
                method: "thread/inject_items",
                params: ["threadId": threadID, "items": [item]]
            ) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if response.value["error"] == nil {
                        self.emitter.emit("l1_tool_advice_attached", fields: [
                            "turn_id": turnID,
                            "tool": tool,
                        ])
                    } else {
                        self.emitter.emit("l1_tool_advice_rejected", fields: [
                            "turn_id": turnID,
                            "tool": tool,
                            "reason": AppServerConnection.responseMessage(response.value),
                        ])
                    }
                }
            }
        case .beginVisualTurn:
            guard let transcript = command.data?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty,
                  let rawEpisodeID = command.taskID,
                  let episodeID = UUID(uuidString: rawEpisodeID) else { return }
            let normalizedTranscript = transcript
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard normalizedTranscript == latestParticipantTranscript else {
                emitter.emit("visual_turn_barrier", fields: [
                    "state": "stale_advice_rejected",
                    "task_id": rawEpisodeID,
                    "reason": "participant_turn_advanced",
                ])
                return
            }
            beginCurrentVisualTurn(
                episodeID: episodeID,
                participantTurnSequence: participantTurnSequence,
                transcript: normalizedTranscript,
                source: "l1_capture_advice"
            )
            emitter.emit("l1_tool_advice_attached", fields: [
                "turn_id": rawEpisodeID,
                "tool": "capture_view",
            ])
        case .stop:
            stop(reason: "control_stop")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewReady = true
        guard !stopping else { return }
        if threadID != nil {
            startWebRTCIfNeeded()
        }
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands { receive(command) }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard !stopping else { return }
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }
        switch event {
        case "offer":
            guard let sdp = body["sdp"] as? String else {
                fail(LiveVoiceError.webRTC("offer_missing_sdp"))
                return
            }
            pendingOfferSDP = sdp
            startRealtimeIfReady()
        case "connected":
            webRTCConnected = true
            activateIfReady()
        case "audio_input_ready":
            emitter.emit("audio_input_ready", fields: [
                "context_state": body["state"] as? String ?? "unknown",
                "track_state": body["trackState"] as? String ?? "unknown",
            ])
        case "audio_input_progress":
            emitter.emit("audio_input_progress")
        case "opening_audio_drained":
            emitter.emit("opening_audio_drained", fields: [
                "item_id": body["itemID"] as? String ?? "",
            ])
        case "opening_audio_rejected":
            emitter.emit("opening_audio_rejected", fields: [
                "item_id": body["itemID"] as? String ?? "",
                "reason": body["reason"] as? String ?? "opening_audio_rejected",
            ])
        case "output_playback_ready":
            emitter.emit("output_playback_ready", fields: [
                "mode": body["mode"] as? String ?? "unknown",
                "route": body["route"] as? String ?? "unknown",
                "effect_profile": body["effectProfile"] as? String ?? "none",
            ])
        case "output_speech_started":
            if observeVisualPresentationStarted(responseID: nil) { return }
            observeAssistantOutputStarted()
        case "output_speech_ended":
            observeAssistantOutputEnded()
        case "output_reference":
            guard let encoded = body["data"] as? String,
                  let sampleRate = body["sampleRate"] as? Int,
                  let channels = body["numChannels"] as? Int,
                  let samplesPerChannel = body["samplesPerChannel"] as? Int,
                  let decoded = Data(base64Encoded: encoded) else { return }
            if observeVisualPresentationStarted(responseID: nil) { return }
            if body["startsOutput"] as? Bool == true {
                observeAssistantOutputStarted()
            }
            noteAssistantAudioActivity()
            let chunk = AssistantPCMChunk(
                data: decoded,
                encoded: encoded,
                sampleRate: sampleRate,
                channels: channels,
                samplesPerChannel: samplesPerChannel,
                source: .webRTCPlayback
            )
            if body["nativePlayback"] as? Bool == true {
                routeAssistantPCM(chunk)
            } else {
                forwardAssistantReference(chunk)
            }
            if body["endsOutput"] as? Bool == true {
                observeAssistantOutputEnded()
            }
        case "realtime_event":
            handleRealtimeDataChannel(body["payload"] as? String ?? "")
        case "closed":
            scheduleTransportClosure(reason: "webrtc_closed")
        case "data_channel_error":
            emitter.emit("transport_warning", fields: [
                "reason": body["message"] as? String ?? "data_channel_failed",
                "data_channel_state": body["dataChannelState"] as? String ?? "unknown",
                "peer_state": body["peerState"] as? String ?? "unknown",
            ])
        case "error":
            fail(LiveVoiceError.webRTC(body["message"] as? String ?? "unknown"))
        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    private func startAppServer() {
        guard let codexURL = Self.codexURL() else {
            fail(LiveVoiceError.codexNotFound)
            return
        }
        emitter.emit("starting", fields: [
            "transport": appServerURL == nil ? "app_server_webrtc" : "persistent_app_server_webrtc",
        ])
        connection.start(
            codexURL: codexURL,
            sessionCapability: sessionCapability,
            appServerURL: appServerURL
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                switch result {
                case .success:
                    self.emitter.emit("app_server_ready")
                    self.startThread()
                case let .failure(error):
                    self.fail(error)
                }
            }
        }
    }

    private func startThread() {
        guard !stopping else { return }
        // When admin-only is enabled, only the local administrator gets the
        // configured Codex sandbox; every other participant is restricted to
        // read-only so a guest cannot create/delete files or touch sensitive
        // paths through the conversation agent.
        let isAdministrator = interactionAuthority == "administrator"
        let effectiveSandbox = (codexAdminOnly && !isAdministrator) ? "read-only" : codexSandbox
        let params: [String: Any] = [
            "cwd": workingDirectory,
            "threadSource": "realtime_voice",
            "ephemeral": true,
            "approvalPolicy": "never",
            "sandbox": effectiveSandbox,
            "config": [
                "model_auto_compact_token_limit": LiveVoiceContextRetentionPolicy.backingAutoCompactTokenLimit,
                "model_auto_compact_token_limit_scope": LiveVoiceContextRetentionPolicy.backingAutoCompactTokenLimitScope,
                "compact_prompt": LiveVoiceContextRetentionPolicy.backingCompactionPrompt,
            ],
        ]
        connection.request(
            method: "thread/start",
            params: params
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                guard response.value["error"] == nil,
                      let result = response.value["result"] as? [String: Any],
                      let thread = result["thread"] as? [String: Any],
                      let threadID = thread["id"] as? String else {
                    self.fail(LiveVoiceError.appServerResponse(
                        AppServerConnection.responseMessage(response.value)
                    ))
                    return
                }
                self.threadID = threadID
                self.emitter.emit("thread_ready", fields: ["thread_id": threadID])
                // Preparing the local offer does not open Realtime. Overlap it
                // with the bounded MCP snapshot, then join both at
                // startRealtimeIfReady().
                self.startWebRTCIfNeeded()
                self.armEmbodimentMCPVerificationTimeout()
                self.verifyEmbodimentMCP(for: threadID)
            }
        }
    }

    private func armEmbodimentMCPVerificationTimeout() {
        embodimentMCPVerificationTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.embodimentMCPVerificationFinished,
                  !self.stopping else { return }
            self.finishEmbodimentMCPVerification(
                available: false,
                reason: "capability_preflight_timeout"
            )
        }
        embodimentMCPVerificationTimeoutWorkItem = work
        let milliseconds = LiveVoiceEmbodimentStartupPolicy.verificationTimeoutMilliseconds
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(milliseconds)),
            execute: work
        )
    }

    private func verifyEmbodimentMCP(for threadID: String) {
        connection.request(
            method: "mcpServerStatus/list",
            params: ["threadId": threadID, "detail": "toolsAndAuthOnly"]
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self,
                      !self.stopping,
                      !self.embodimentMCPVerificationFinished else { return }
                let statuses = (response.value["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
                let server = statuses.first { $0["name"] as? String == "soma_embodiment" }
                let tools = server?["tools"] as? [String: Any]
                let personToolsAvailable = self.personContextReference == nil || (
                    tools?["get_person_context"] != nil && tools?["list_information_needs"] != nil
                )
                let hermesToolsAvailable = !self.hermesAgentDelegationEnabled
                    || tools?["delegate_hermes_task"] != nil
                self.embodimentMCPAvailable = response.value["error"] == nil
                    && tools?["capture_view"] != nil
                    && tools?["get_view_capture"] != nil
                    && tools?["end_conversation"] != nil
                    && personToolsAvailable
                    && hermesToolsAvailable
                guard self.embodimentMCPAvailable else {
                    self.finishEmbodimentMCPVerification(
                        available: false,
                        reason: response.value["error"] == nil
                            ? "required_mcp_tools_missing"
                            : AppServerConnection.responseMessage(response.value)
                    )
                    return
                }
                self.embodimentBodyCheckFinished = false
                self.embodimentBodyCheckAvailable = false
                self.embodimentBodyCheckFailureReason = nil
                self.personContextCheckFinished = self.personContextReference == nil
                self.personContextAvailable = false
                self.verifyEmbodimentCapability(for: threadID)
                if let personEntityID = self.personContextReference {
                    self.verifyPersonContextCapability(
                        for: threadID,
                        personEntityID: personEntityID
                    )
                }
            }
        }
    }

    private func verifyEmbodimentCapability(for threadID: String) {
        connection.request(
            method: "mcpServer/tool/call",
            params: [
                "threadId": threadID,
                "server": "soma_embodiment",
                "tool": "get_robot_body_state",
                "arguments": [
                    "cognitive_intent": preflightIntent(
                        purpose: "Verify the current session's bounded embodiment capability."
                    ),
                ],
            ]
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self,
                      !self.stopping,
                      !self.embodimentMCPVerificationFinished else { return }
                let result = response.value["result"] as? [String: Any]
                let toolFailed = (result?["isError"] as? Bool) == true
                self.embodimentBodyCheckAvailable = response.value["error"] == nil && !toolFailed
                self.embodimentBodyCheckFinished = true
                if self.embodimentBodyCheckAvailable {
                    self.embodimentBodyCheckFailureReason = nil
                } else {
                    let reason: String
                    if response.value["error"] != nil {
                        reason = AppServerConnection.responseMessage(response.value)
                    } else if let content = result?["content"] as? [[String: Any]],
                              let text = content.compactMap({ $0["text"] as? String }).first,
                              !text.isEmpty {
                        reason = text
                    } else {
                        reason = "capability_preflight_failed"
                    }
                    self.embodimentBodyCheckFailureReason = reason
                }
                self.finishParallelEmbodimentVerificationIfReady()
            }
        }
    }

    private func verifyPersonContextCapability(for threadID: String, personEntityID: UUID) {
        connection.request(
            method: "mcpServer/tool/call",
            params: [
                "threadId": threadID,
                "server": "soma_embodiment",
                "tool": "get_person_context",
                "arguments": [
                    "person_entity_id": personEntityID.uuidString.lowercased(),
                    "cognitive_intent": preflightIntent(
                        purpose: "Verify the current session's bounded person-context capability."
                    ),
                ],
            ]
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self,
                      !self.stopping,
                      !self.embodimentMCPVerificationFinished else { return }
                let result = response.value["result"] as? [String: Any]
                let toolFailed = (result?["isError"] as? Bool) == true
                self.personContextAvailable = response.value["error"] == nil && !toolFailed
                self.personContextCheckFinished = true
                if self.personContextAvailable {
                    self.emitter.emit("person_context_ready")
                } else {
                    let reason: String
                    if response.value["error"] != nil {
                        reason = AppServerConnection.responseMessage(response.value)
                    } else if let content = result?["content"] as? [[String: Any]],
                              let text = content.compactMap({ $0["text"] as? String }).first,
                              !text.isEmpty {
                        reason = text
                    } else {
                        reason = "person_context_preflight_failed"
                    }
                    self.emitter.emit("person_context_unavailable", fields: [
                        "reason": String(reason.prefix(192)),
                    ])
                }
                self.finishParallelEmbodimentVerificationIfReady()
            }
        }
    }

    private func finishParallelEmbodimentVerificationIfReady() {
        guard !stopping,
              embodimentBodyCheckFinished,
              personContextCheckFinished,
              !embodimentMCPVerificationFinished else { return }
        finishEmbodimentMCPVerification(
            available: embodimentBodyCheckAvailable,
            reason: embodimentBodyCheckFailureReason
        )
    }

    private func finishEmbodimentMCPVerification(available: Bool, reason: String? = nil) {
        guard !stopping, !embodimentMCPVerificationFinished else { return }
        embodimentMCPVerificationTimeoutWorkItem?.cancel()
        embodimentMCPVerificationTimeoutWorkItem = nil
        embodimentMCPAvailable = available
        embodimentMCPVerificationFinished = true
        if available {
            emitter.emit("embodiment_mcp_ready")
        } else {
            emitter.emit("embodiment_mcp_unavailable", fields: [
                "reason": String((reason ?? "capability_preflight_failed").prefix(192)),
            ])
        }
        startRealtimeIfReady()
    }

    private func preflightIntent(purpose: String) -> [String: Any] {
        [
            "goal_episode_id": preflightGoalEpisodeID.uuidString.lowercased(),
            "purpose": purpose,
            "expected_information_gain": 0,
            "evidence_ids": [],
            "authorization_basis": L2CognitiveAuthorizationBasis.autonomousGoal.rawValue,
        ]
    }

    private func startWebRTCIfNeeded() {
        guard !stopping,
              LiveVoiceEmbodimentStartupPolicy.permitsTransportPreparation(
            webViewReady: webViewReady,
            threadReady: threadID != nil,
            transportAlreadyStarted: webRTCStarted
        ) else { return }
        webRTCStarted = true
        let outputName = selectedAudioOutput?.selectedName ?? ""
        guard let encodedName = try? JSONEncoder().encode(outputName),
              let nameLiteral = String(data: encodedName, encoding: .utf8) else {
            fail(LiveVoiceError.webRTC("output_device_name_encoding_failed"))
            return
        }
        let useSystemDefault = selectedAudioOutput?.isSystemDefault ?? true
        let useVoiceEffects = voiceMode.requiresProcessedPlayback
        let browserProfile: [String: Any]
        if useVoiceEffects {
            let profile = SOMARealtimeVoiceDSPProfile.spaceMarine
            browserProfile = [
                "pitchCents": profile.pitchCents,
                "echoFeedback": profile.echoStages.map { $0.feedbackPercent / 100 },
                "echoWet": profile.echoStages.map { $0.wetDryMixPercent / 100 },
                "reverbWet": profile.reverbWetDryMix / 100,
            ]
        } else {
            browserProfile = [:]
        }
        guard let profileData = try? JSONSerialization.data(withJSONObject: browserProfile),
              let profileLiteral = String(data: profileData, encoding: .utf8) else {
            fail(LiveVoiceError.webRTC("voice_effect_profile_encoding_failed"))
            return
        }
        webView.evaluateJavaScript(
            "void startWebRTC(\(nameLiteral), \(useSystemDefault ? "true" : "false"), \(useVoiceEffects ? "true" : "false"), \(profileLiteral))"
        ) { [weak self] _, error in
            if let error { self?.fail(error) }
        }
    }

    private func startRealtimeIfReady() {
        guard !stopping,
              threadID != nil,
              LiveVoiceEmbodimentStartupPolicy.permitsRealtimeStart(
            offerReady: pendingOfferSDP != nil,
            capabilityVerificationFinished: embodimentMCPVerificationFinished,
            realtimeAlreadyStarted: realtimeStartRequested
        ), let offerSDP = pendingOfferSDP else { return }
        pendingOfferSDP = nil
        realtimeStartRequested = true
        startRealtime(offerSDP: offerSDP)
    }

    private func injectCameraImage(_ dataURI: String, into threadID: String) {
        let item: [String: Any] = [
            "type": "message",
            "role": "developer",
            "content": [
                [
                    "type": "input_text",
                    "text": "Current SOMA camera frame — passive sensor context, NOT a request to describe it. It is what the robot currently sees, for understanding the user's situation. Always respond to the user's actual spoken message. Never narrate or describe this image unless the user explicitly asks what you see.",
                ],
                [
                    "type": "input_image",
                    "image_url": dataURI,
                    "detail": "low",
                ],
            ],
        ]
        connection.request(
            method: "thread/inject_items",
            params: ["threadId": threadID, "items": [item]]
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard response.value["error"] == nil else {
                    self.emitter.emit("visual_context_rejected", fields: [
                        "reason": AppServerConnection.responseMessage(response.value),
                    ])
                    return
                }
                self.emitter.emit("visual_context_attached")
            }
        }
    }

    private func beginCurrentVisualTurn(
        episodeID: UUID,
        participantTurnSequence: UInt64,
        transcript: String,
        source: String
    ) {
        guard let threadID, embodimentMCPAvailable else {
            emitter.emit("visual_turn_barrier", fields: [
                "state": "unavailable",
                "task_id": episodeID.uuidString.lowercased(),
                "reason": "embodiment_mcp_unavailable",
            ])
            return
        }
        let boundedTranscript = String(transcript.prefix(4_096))
        if let current = visualResponseBarrier,
           current.participantTurnSequence == participantTurnSequence {
            emitter.emit("visual_turn_barrier", fields: [
                "state": "already_armed",
                "task_id": current.episodeID.uuidString.lowercased(),
                "reason": source,
            ])
            return
        }
        if visualResponseBarrier?.presentationReleased == true {
            completeCurrentVisualResponse()
        }
        if let current = visualResponseBarrier {
            emitter.emit("visual_turn_barrier", fields: [
                "state": "superseded",
                "task_id": current.episodeID.uuidString.lowercased(),
                "reason": "newer_participant_turn",
            ])
        }
        visualCancellationTimeoutWorkItem?.cancel()
        visualCancellationTimeoutWorkItem = nil
        visualReplacementTimeoutWorkItem?.cancel()
        visualReplacementTimeoutWorkItem = nil
        let barrier = LiveVoiceVisualResponseBarrier(
            episodeID: episodeID,
            participantTurnSequence: participantTurnSequence,
            transcript: boundedTranscript,
            provisionalResponseID: currentRealtimeResponseID
        )
        visualResponseBarrier = barrier
        emitter.emit("visual_turn_barrier", fields: [
            "state": "armed",
            "task_id": episodeID.uuidString.lowercased(),
            "reason": source,
        ])
        applyVisualBarrierActions(barrier.initialActions, episodeID: episodeID, threadID: threadID)
        scheduleVisualCancellationTimeout(episodeID: episodeID)
    }

    private func observeVisualResponseStarted(responseID: String?) -> Bool {
        guard var barrier = visualResponseBarrier else { return false }
        let actions = barrier.observeResponseStarted(responseID: responseID)
        visualResponseBarrier = barrier
        if let threadID {
            applyVisualBarrierActions(actions, episodeID: barrier.episodeID, threadID: threadID)
        }
        return barrier.suppressesAssistantPresentation
    }

    private func observeVisualPresentationStarted(responseID: String?) -> Bool {
        guard var barrier = visualResponseBarrier else { return false }
        let actions = barrier.observePresentationStarted(responseID: responseID)
        visualResponseBarrier = barrier
        if let threadID {
            applyVisualBarrierActions(actions, episodeID: barrier.episodeID, threadID: threadID)
        }
        if barrier.presentationReleased {
            visualReplacementTimeoutWorkItem?.cancel()
            visualReplacementTimeoutWorkItem = nil
        }
        return barrier.suppressesAssistantPresentation
    }

    private func observeVisualResponseEnded(responseID: String?) {
        guard var barrier = visualResponseBarrier else { return }
        let actions = barrier.observeResponseEnded(responseID: responseID)
        visualResponseBarrier = barrier
        if barrier.provisionalResponseSettled {
            visualCancellationTimeoutWorkItem?.cancel()
            visualCancellationTimeoutWorkItem = nil
        }
        if let threadID {
            applyVisualBarrierActions(actions, episodeID: barrier.episodeID, threadID: threadID)
        }
    }

    private func observeVisualCancellationSettled(episodeID: UUID) {
        guard var barrier = visualResponseBarrier else { return }
        guard barrier.episodeID == episodeID else { return }
        let actions = barrier.observeProvisionalResponseSettled(cancellationAcknowledged: true)
        visualResponseBarrier = barrier
        visualCancellationTimeoutWorkItem?.cancel()
        visualCancellationTimeoutWorkItem = nil
        if let threadID {
            applyVisualBarrierActions(actions, episodeID: barrier.episodeID, threadID: threadID)
        }
    }

    private func completeCurrentVisualResponse() {
        guard let barrier = visualResponseBarrier,
              barrier.phase == .presentingReplacementResponse else { return }
        cancelVisualTurnTimeouts()
        visualResponseBarrier = nil
        setVisualOutputGate(closed: false)
        emitter.emit("visual_turn_barrier", fields: [
            "state": "completed",
            "task_id": barrier.episodeID.uuidString.lowercased(),
            "reason": "single_grounded_response",
        ])
    }

    private func cancelVisualTurnTimeouts() {
        visualCancellationTimeoutWorkItem?.cancel()
        visualCancellationTimeoutWorkItem = nil
        visualReplacementTimeoutWorkItem?.cancel()
        visualReplacementTimeoutWorkItem = nil
    }

    private func scheduleVisualCancellationTimeout(episodeID: UUID) {
        visualCancellationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.visualResponseBarrier?.episodeID == episodeID,
                  self.visualResponseBarrier?.provisionalResponseSettled == false else { return }
            self.fail(LiveVoiceError.webRTC("visual_response_cancellation_timed_out"))
        }
        visualCancellationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(VisualTurnTransportPolicy.cancellationTimeoutMilliseconds),
            execute: workItem
        )
    }

    private func scheduleVisualReplacementTimeout(episodeID: UUID) {
        visualReplacementTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.visualResponseBarrier?.episodeID == episodeID,
                  self.visualResponseBarrier?.presentationReleased == false else { return }
            self.fail(LiveVoiceError.webRTC("visual_replacement_response_timed_out"))
        }
        visualReplacementTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(
                VisualTurnTransportPolicy.replacementPresentationTimeoutMilliseconds
            ),
            execute: workItem
        )
    }

    private func applyVisualBarrierActions(
        _ actions: [LiveVoiceVisualResponseBarrier.Action],
        episodeID: UUID,
        threadID: String
    ) {
        for action in actions {
            switch action {
            case .closeOutput:
                setVisualOutputGate(closed: true, resetPresentation: true)
            case .acquireEvidence:
                if visualEvidenceInjectionInFlightEpisodeID != nil {
                    deferredVisualEvidenceEpisodeID = episodeID
                    emitter.emit("visual_turn_barrier", fields: [
                        "state": "evidence_deferred",
                        "task_id": episodeID.uuidString.lowercased(),
                        "reason": "prior_injection_in_flight",
                    ])
                } else {
                    acquireCurrentVisualEvidence(episodeID: episodeID, threadID: threadID)
                }
            case .cancelResponse:
                sendRealtimeControlEvent(
                    type: "response.cancel",
                    episodeID: episodeID,
                    failureIsFatal: true
                )
                sendRealtimeControlEvent(
                    type: "output_audio_buffer.clear",
                    episodeID: episodeID
                )
                emitter.emit("visual_turn_barrier", fields: [
                    "state": "response_cancel_requested",
                    "task_id": episodeID.uuidString.lowercased(),
                    "reason": "awaiting_current_frame",
                ])
            case .requestResponse:
                setVisualOutputGate(closed: true, resetPresentation: true)
                currentRealtimeResponseID = nil
                sendRealtimeControlEvent(
                    type: "response.create",
                    episodeID: episodeID,
                    failureIsFatal: true
                )
                emitter.emit("visual_turn_barrier", fields: [
                    "state": "response_requested",
                    "task_id": episodeID.uuidString.lowercased(),
                    "reason": "evidence_committed",
                ])
                scheduleVisualReplacementTimeout(episodeID: episodeID)
            case .openOutput:
                setVisualOutputGate(closed: false)
                emitter.emit("visual_turn_barrier", fields: [
                    "state": "presentation_released",
                    "task_id": episodeID.uuidString.lowercased(),
                    "reason": "replacement_response_started",
                ])
            }
        }
    }

    private func sendRealtimeControlEvent(
        type: String,
        episodeID: UUID,
        failureIsFatal: Bool = false
    ) {
        let event: [String: Any] = [
            "type": type,
            "event_id": "soma_\(episodeID.uuidString.lowercased())_\(type.replacingOccurrences(of: ".", with: "_"))",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("sendRealtimeControl(\(literal))") { [weak self] result, error in
            guard error == nil, (result as? Bool) == true else {
                guard let self else { return }
                let reason = error?.localizedDescription ?? "data_channel_unavailable"
                self.emitter.emit("visual_turn_barrier", fields: [
                    "state": "control_rejected",
                    "task_id": episodeID.uuidString.lowercased(),
                    "reason": reason,
                ])
                if failureIsFatal {
                    self.fail(LiveVoiceError.webRTC("visual_response_request_failed: \(reason)"))
                }
                return
            }
        }
    }

    private func setVisualOutputGate(closed: Bool, resetPresentation: Bool = false) {
        if closed { selectedAudioOutput?.flush() }
        webView.evaluateJavaScript(
            "setVisualOutputGate(\(closed ? "true" : "false"), \(resetPresentation ? "true" : "false"))"
        )
    }

    private func acquireCurrentVisualEvidence(episodeID: UUID, threadID: String) {
        connection.request(
            method: "mcpServer/tool/call",
            params: [
                "threadId": threadID,
                "server": "soma_embodiment",
                "tool": "capture_view",
                "arguments": [:],
            ],
            timeoutMilliseconds: VisualTurnTransportPolicy.captureTimeoutMilliseconds
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self,
                      self.visualResponseBarrier?.episodeID == episodeID else { return }
                let result = response.value["result"] as? [String: Any]
                let failed = response.value["error"] != nil || (result?["isError"] as? Bool) == true
                let content = result?["content"] as? [[String: Any]] ?? []
                let text = content
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                let imageDataURI = content.lazy.compactMap { item -> String? in
                    guard item["type"] as? String == "image",
                          let data = item["data"] as? String,
                          !data.isEmpty else { return nil }
                    let mimeType = (item["mimeType"] as? String)
                        ?? (item["mime_type"] as? String)
                        ?? "image/jpeg"
                    return "data:\(mimeType);base64,\(data)"
                }.first
                let captureSucceeded = !failed && imageDataURI != nil
                self.emitter.emit("embodiment_mcp_call", fields: [
                    "tool": "capture_view",
                    "status": captureSucceeded ? "completed" : "failed",
                    "error": captureSucceeded
                        ? ""
                        : AppServerConnection.responseMessage(response.value),
                    "item_id": episodeID.uuidString.lowercased(),
                ])
                self.injectCurrentVisualEvidence(
                    episodeID: episodeID,
                    threadID: threadID,
                    imageDataURI: imageDataURI,
                    captureText: text,
                    captureSucceeded: captureSucceeded
                )
            }
        }
    }

    private func injectCurrentVisualEvidence(
        episodeID: UUID,
        threadID: String,
        imageDataURI: String?,
        captureText: String,
        captureSucceeded: Bool
    ) {
        guard let barrier = visualResponseBarrier,
              barrier.episodeID == episodeID else { return }
        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": captureSucceeded
                ? "SOMA_CURRENT_VISUAL_EVIDENCE \(episodeID.uuidString.lowercased())\nThis camera evidence was captured after the latest participant utterance and belongs only to that turn. Answer that utterance once using this evidence. Do not issue another capture_view call for the same turn.\n\(String(captureText.prefix(4_096)))"
                : "SOMA_CURRENT_VISUAL_EVIDENCE_FAILURE \(episodeID.uuidString.lowercased())\nThe required fresh camera capture failed. Answer the latest participant utterance once and state the concrete sensor failure briefly; do not guess visual facts.",
        ]]
        if let imageDataURI {
            content.append([
                "type": "input_image",
                "image_url": imageDataURI,
                "detail": "low",
            ])
        }
        let item: [String: Any] = [
            "type": "message",
            "role": "developer",
            "content": content,
        ]
        guard visualEvidenceInjectionInFlightEpisodeID == nil else {
            deferredVisualEvidenceEpisodeID = episodeID
            return
        }
        visualEvidenceInjectionInFlightEpisodeID = episodeID
        connection.request(
            method: "thread/inject_items",
            params: ["threadId": threadID, "items": [item]],
            timeoutMilliseconds: VisualTurnTransportPolicy.evidenceInjectionTimeoutMilliseconds
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard var current = self.visualResponseBarrier,
                      current.episodeID == episodeID else {
                    self.emitter.emit("visual_turn_barrier", fields: [
                        "state": "superseded_evidence_settled",
                        "task_id": episodeID.uuidString.lowercased(),
                        "reason": response.value["error"] == nil
                            ? "newer_turn_waited_for_injection"
                            : AppServerConnection.responseMessage(response.value),
                    ])
                    if AppServerConnection.responseTimedOut(response.value) {
                        self.fail(LiveVoiceError.appServerResponse(
                            "superseded_visual_evidence_injection_timed_out"
                        ))
                        return
                    }
                    self.finishVisualEvidenceInjection(episodeID: episodeID)
                    return
                }
                guard response.value["error"] == nil else {
                    self.emitter.emit("visual_turn_barrier", fields: [
                        "state": "evidence_rejected",
                        "task_id": episodeID.uuidString.lowercased(),
                        "reason": AppServerConnection.responseMessage(response.value),
                    ])
                    self.finishVisualEvidenceInjection(episodeID: episodeID)
                    self.fail(LiveVoiceError.appServerResponse(
                        "visual_evidence_injection_failed: \(AppServerConnection.responseMessage(response.value))"
                    ))
                    return
                }
                let actions = current.observeEvidenceCommitted()
                self.visualResponseBarrier = current
                self.emitter.emit("visual_turn_barrier", fields: [
                    "state": captureSucceeded ? "evidence_committed" : "failure_committed",
                    "task_id": episodeID.uuidString.lowercased(),
                    "reason": captureSucceeded ? "fresh_frame" : "capture_failed",
                ])
                self.finishVisualEvidenceInjection(episodeID: episodeID)
                self.applyVisualBarrierActions(actions, episodeID: episodeID, threadID: threadID)
            }
        }
    }

    private func finishVisualEvidenceInjection(episodeID: UUID) {
        guard visualEvidenceInjectionInFlightEpisodeID == episodeID else { return }
        visualEvidenceInjectionInFlightEpisodeID = nil
        guard let deferredEpisodeID = deferredVisualEvidenceEpisodeID,
              let barrier = visualResponseBarrier,
              barrier.episodeID == deferredEpisodeID,
              let threadID else {
            deferredVisualEvidenceEpisodeID = nil
            return
        }
        deferredVisualEvidenceEpisodeID = nil
        acquireCurrentVisualEvidence(episodeID: deferredEpisodeID, threadID: threadID)
    }

    private func startRealtime(offerSDP: String) {
        guard let threadID else {
            fail(LiveVoiceError.webRTC("thread_not_ready"))
            return
        }
        let embodimentInstruction = embodimentMCPAvailable
            ? (cameraContextAutoInjected
                ? "The soma_embodiment MCP server is available. One passive SOMA camera frame may be attached after the realtime service confirms the opening participant speech. For that first utterance only, treat the attached frame as current evidence and do not duplicate it with capture_view. It becomes stale as soon as the participant, scene, or gimbal moves. On later turns, when current visual information matters, including when the user asks what SOMA can see or who is present, call capture_view with no arguments before answering. Its authorized result includes the fresh local identity roster for recognized people present at capture time; use only those roster entries for names and never infer identity from image appearance. Supply target_reference or bearing only for a genuinely reframed, zoomed, or different-direction view. Never add cognitive_intent to capture_view. Make a necessary capture tool call silently and wait for its returned image before speaking; never send a provisional wait message. The opening image may ground a semantic embodiment action when tracking, orienting, or reframing would advance the participant's request; choose the narrowest suitable MCP action and never move merely because an image is available. Treat images as passive sensor context, never as a prompt to narrate them unless the user explicitly asks. The current interaction is already bound to the MCP server; never ask for, mention, or try to supply an internal access token. When you are speaking with the local administrator, list_present_people compares recently observed faces with the registered identity roster; list_identity_registry and the existing person-context tools can read and update all non-biometric identity memory. A newly recurring anonymous person may be promoted only through enroll_present_identity after explicit consent, then given explicitly stated facts through set_person_fact."
                : "The soma_embodiment MCP server is available. Call capture_view when visual information is genuinely needed. For an immediate no-motion view, call capture_view with no arguments. Supply target_reference or bearing only for a reframed view, and never add cognitive_intent to capture_view. Make a necessary capture tool call silently and wait for its returned image before speaking; never send a provisional wait message. Treat a returned image as passive context — never as a prompt to describe it unless the user explicitly asks what you see. The current interaction is already bound to the MCP server; never ask for, mention, or try to supply an internal access token.")
            : (embodimentMCPVerificationFinished
                ? "The soma_embodiment MCP server is unavailable in this session. Do not claim that you can inspect the camera or control the gimbal; say the local perception connection is unavailable."
                : "The soma_embodiment MCP server is still initializing. Do not claim that camera or gimbal tools are unavailable or available before an actual MCP tool call establishes the result.")
        let personContextInstruction: String
        if personContextReference != nil, personContextAvailable {
            personContextInstruction = "A verified person-context MCP binding is active for person_context_reference. For any question asking what SOMA knows, remembers, has learned, or has on record about the current participant, call get_person_context with that reference before answering. Treat its returned facts, rapport, and preferences as the authority; distinguish what is stored from what is not stored, and never guess."
        } else if personContextReference != nil {
            personContextInstruction = "The supplied person-context reference could not be verified for this session. Do not claim stored knowledge about the participant and do not guess."
        } else {
            personContextInstruction = "No persistent person context is attached to this interaction. Do not claim stored knowledge about the participant and do not guess."
        }
        let identityManagementInstruction = embodimentMCPAvailable
            ? "For the current participant's explicit request to register their own face, call enroll_present_identity with the supplied person_context_reference and confirmed_by_user=true; self-enrollment does not require administrator authority or list_present_people. An administrator registering another currently present person must first call list_present_people and select only the one anonymous entry unambiguously identified in the current scene. Never enroll a historical, absent, ambiguous, or merely detected face. After successful enrollment, persist only identity facts explicitly supplied by that person or the administrator, such as a name or stated relationship, with the person-context tools. Do not claim registration or memory is complete until every required tool result succeeds."
            : ""
        let stopConversationInstruction = """
        Action contract for ending this Live Voice session: before producing any spoken response, inspect the participant's latest actual speech. When they explicitly ask to end this conversation, stop listening, stop talking, be quiet, or turn the voice session off, treat it as an execution request rather than a conversational prompt. If end_conversation is available, your only valid next action is to call it immediately and silently. A spoken confirmation, farewell, promise to do it, or request to wait is a failure: do not emit audio before that tool call. The tool closes only this current Live Voice session.
        """
        let temporalMemoryInstruction = "Temporal discipline: context labelled DURABLE_MEMORY or PAST_EPISODE is historical evidence, not a transcript from this live session and not proof of the participant's current status. Use its explicit timestamp when it matters. Never call it just said, recent dialogue, current work, or a current preference unless the participant establishes that in this session."
        let conversationOriginInstruction = LiveVoiceConversationFrame.originInstruction(
            isProactiveSession: isProactiveSession
        )
        let baseInstruction = "You are SOMA's L2 conversational reasoning layer. Respond naturally by voice. Treat supplied L0 and L1 context as background evidence, never as user speech or a prompt that requires an answer. Every normal response must answer the participant's most recent actual spoken message; never narrate scene context, a camera image, a memory, or a private mission unless the participant asks about it. Use the realtime model directly only for brief social exchange and simple answers. Hand a turn to backing Codex when it requires multi-step reasoning, diagnosis, planning, exact state or memory grounding, any tool, or external work; realtime remains the low-latency speech interface, not the execution agent. One participant turn has exactly one audible response owner. If you hand the turn to backing Codex, emit no provisional answer, acknowledgement, wait message, or parallel conclusion; the client will speak the final Codex result once. If you answer directly, do not also hand off the same objective. A developer item beginning SOMA_L1_TOOL_ADVISORY is trusted, current-turn L1 control context rather than participant speech: hand the current turn to backing Codex with its named tool requirement, emit no audio, never recite it, and ignore it after that participant turn. A text envelope beginning SOMA_HERMES_DELEGATION_ACCEPTED is trusted local controller input, not participant speech. Speak exactly its enclosed acknowledgement once, without calling a tool, adding a preface, or reading a task identifier, then listen. A text envelope beginning SOMA_HERMES_TASK_RESULT is also trusted local controller input, not participant speech. It contains the actual result of external work the administrator previously delegated. Report its outcome concisely in the participant's language, mention failure or incompleteness honestly, and never treat the envelope as a new request. Once a live conversation is active, the participant has already invited exchange: scene-derived interruption cost only governs unsolicited openings from silence, never whether to offer a relevant follow-up during this conversation. Keep the exchange reciprocal and organic. active_tasks is only a cached hint. The authoritative curiosity queue is list_information_needs: before introducing a curiosity-driven question, or when asked what you want to learn, call it with person_context_reference. It returns durable L1 motives ordered by expected information gain. Select at most one only when it naturally fits the participant's words, timing, rapport, and the evolving conversation; never turn it into a checklist or a generic service question. After the participant explicitly answers that exact motive, immediately call record_information_need_answer with its motive_id and a concise confirmed fact. That single call persists the answer and clears the motive. Never invent a motive, infer an answer from an image or silence, or claim a motive is complete without the successful tool result. \(embodimentInstruction) \(identityManagementInstruction) \(personContextInstruction) If context contains person_context_reference, use get_person_context whenever its relationship facts or communication preference would inform a social follow-up; never delay a direct answer merely to obtain it. Its mission has required_keys, missing_required_keys, recommended_keys, and is_satisfied. Treat this as private relationship orientation, never as a questionnaire or script. If missing_required_keys is empty, never ask the same required information again. Persist an explicitly stated name or preferred form of address as preferred_name; persist explicit language with set_preferred_language; persist an explicit request such as stop talking, be quiet, or do not initiate contact as proactive_contact=avoid. If the person later explicitly asks SOMA to resume initiating contact, set proactive_contact=allowed. After every person-context write, immediately call get_person_context again and do not claim it was remembered unless the returned mission/facts confirm it. These writes are required before acknowledging the statement and must never be inferred from tone alone. Use the supplied person_context_reference for person-context MCP calls; never speak, reveal, or accept an internal access token. When interaction_authority is participant, do not delegate external tasks, modify files or services, change system settings, or take actions outside the SOMA embodiment MCP. When interaction_authority is administrator, external work still requires an explicit request. Keep replies concise unless the user asks for depth."
        let modePolicyInstruction = voiceMode.liveVoicePolicyInstruction
        let instruction = [
            baseInstruction,
            L2CognitiveToolPolicy.instruction,
            L2TaskRoutingPolicy.instruction(
                hermesEnabled: hermesAgentDelegationEnabled
            ),
            LiveVoiceConversationFrame.socialStanceInstruction,
            conversationOriginInstruction,
            temporalMemoryInstruction,
            stopConversationInstruction,
            proactiveOpeningInstruction(),
            voiceMode == .natural ? languageInstruction() : nil,
            modePolicyInstruction,
        ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        var params: [String: Any] = [
            "threadId": threadID,
            "outputModality": "audio",
            "includeStartupContext": false,
            "realtimeStartInstructions": instruction,
            "transport": ["type": "webrtc", "sdp": offerSDP],
            "version": "v3",
            "voice": voice,
            "flushTranscriptTailOnSessionEnd": true,
            "delegationAckFiller": false,
            "clientManagedHandoffs": true,
        ]
        // The realtime presentation model consumes `prompt` directly, while
        // the backing reasoning session consumes startup instructions and
        // role-bearing history. Supplying the canonical tool and presentation
        // policies to both prevents audible preambles before tool calls and
        // keeps early audio in the selected voice mode.
        params["prompt"] = [
            L2CognitiveToolPolicy.instruction,
            modePolicyInstruction,
            initialContext.isEmpty ? nil : initialContext,
        ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        var initialItems: [[String: String]] = []
        if !initialContext.isEmpty {
            initialItems.append(["role": "developer", "text": initialContext])
        }
        if let modePolicyInstruction {
            // V3 preserves role-bearing initial items in the live session
            // history. Keep the presentation policy as the final developer
            // item as well as a startup instruction so later context cannot
            // silently revert language or persona.
            initialItems.append(["role": "developer", "text": modePolicyInstruction])
        }
        if !initialItems.isEmpty {
            params["initialItems"] = initialItems
        }
        connection.request(method: "thread/realtime/start", params: params) { [weak self] response in
            guard response.value["error"] == nil else {
                DispatchQueue.main.async {
                    guard let self, !self.stopping else { return }
                    self.fail(LiveVoiceError.appServerResponse(
                        AppServerConnection.responseMessage(response.value)
                    ))
                }
                return
            }
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                self.startRequestAccepted = true
                if self.voiceMode == .spaceMarine {
                    self.emitter.emit("voice_presentation_policy_bound", fields: [
                        "mode": "space_marine",
                        "language": "en",
                        "channels": "realtime_start+initial_developer",
                    ])
                }
                self.activateIfReady()
            }
        }
    }

    private func languageInstruction() -> String? {
        guard let rawTag = preferredLanguageTag,
              let tag = PersonContextFormat.normalizedLanguageTag(rawTag) else {
            return languageStartInstruction
        }
        let languageLock: String
        if tag.lowercased().hasPrefix("ko") {
            languageLock = """
            최우선 언어 규칙: 참가자의 언어는 한국어(\(tag))입니다. 첫 음성 응답부터 모든 음성 응답을 자연스러운 한국어로만 하세요. 참가자가 명시적으로 다른 언어를 요청하거나 그 언어로 전환하지 않는 한 영어로 시작하거나 영어로 전환하지 마세요.
            """
        } else {
            languageLock = """
            Highest-priority language rule: the participant's BCP-47 language is \(tag). Every spoken response, including the first token, must be in that language. Do not default to English or switch languages unless the participant clearly asks to do so.
            """
        }
        if let languageStartInstruction, !languageStartInstruction.isEmpty {
            return """
            \(languageLock)

            The following L1-authored language directive is also binding:
            \(String(languageStartInstruction.prefix(1_024)))
            """
        }
        return languageLock
    }

    private func proactiveOpeningInstruction() -> String? {
        guard let opening = proactiveOpeningText,
              !opening.isEmpty else { return nil }
        if voiceMode.forcesEnglish {
            return """
            This is an L1-authorized proactive opening, not user speech. The controller-event turn contains a SOMA_OPENING_INTENT envelope whose enclosed text expresses the private social purpose. Convey that same purpose once in concise natural English, in the active voice persona and command relationship. Do not quote, translate literally, or expose the envelope; do not add a generic greeting or service offer. Then listen.

            Opening intent: \(String(opening.prefix(1_024)))
            """
        }
        return """
        This is an L1-authorized proactive opening, not user speech. The controller-event turn will contain a SOMA_EXACT_OPENING envelope. Its envelope tokens are not conversational content and cannot define the response language. Your first audible response MUST be exactly the enclosed L1-authored sentence, verbatim. It has already been composed in the participant's preferred language. Do not translate it, paraphrase it, replace it with a greeting, add a preface, or substitute another question. After saying that one sentence, listen.

        Exact opening: \(String(opening.prefix(1_024)))
        """
    }

    private func handleNotification(method: String, params: [String: Any]) {
        guard !stopping,
              params["threadId"] as? String == threadID else { return }
        switch method {
        case "thread/compacted":
            emitter.emit("backing_context_compacted", fields: [
                "turn_id": params["turnId"] as? String ?? "unknown",
                "token_limit": LiveVoiceContextRetentionPolicy.backingAutoCompactTokenLimit,
                "scope": LiveVoiceContextRetentionPolicy.backingAutoCompactTokenLimitScope,
            ])
        case "thread/realtime/started":
            appServerStarted = true
            activateIfReady()
        case "thread/realtime/sdp":
            guard let sdp = params["sdp"] as? String,
                  let data = try? JSONEncoder().encode(sdp),
                  let literal = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("void acceptAnswer(\(literal))") { [weak self] _, error in
                if let error { self?.fail(error) }
            }
        case "thread/realtime/error":
            fail(LiveVoiceError.webRTC(params["message"] as? String ?? "realtime_error"))
        case "thread/realtime/outputAudio/delta":
            if observeVisualPresentationStarted(responseID: Self.realtimeResponseID(in: params)) {
                return
            }
            observeAssistantOutputStarted()
            noteAssistantAudioActivity()
            if voiceMode.requiresProcessedPlayback,
               let chunk = Self.appServerAudioChunk(from: params),
               LiveVoicePlaybackOwnershipPolicy.disposition(
                   for: chunk.source
               ).mayFeedEchoReference {
                // App Server PCM is upstream reference telemetry. Playback is
                // owned exclusively by the WebRTC render graph (or its muted
                // native fallback) so the same response cannot reach the
                // speaker through two independent paths.
                forwardAssistantReference(chunk)
            }
        case "thread/realtime/transcript/delta":
            guard params["role"] as? String == "user",
                  let delta = params["delta"] as? String,
                  !delta.isEmpty else { return }
            observeInputSpeechStarted()
            if delta.hasPrefix(partialUserTranscript) {
                partialUserTranscript = String(delta.prefix(4_096))
            } else {
                partialUserTranscript = String((partialUserTranscript + delta).prefix(4_096))
            }
            emitter.emit("transcript_partial", fields: [
                "thread_id": threadID ?? "",
                "text": partialUserTranscript,
            ])
        case "thread/realtime/transcript/done":
            guard let role = params["role"] as? String,
                  ["user", "assistant"].contains(role),
                  let text = params["text"] as? String,
                  !text.isEmpty else { return }
            emitFinalizedTranscript(
                role: role,
                text: text,
                itemID: (params["itemId"] as? String) ?? (params["item_id"] as? String),
                origin: .appServer
            )
        case "thread/realtime/closed":
            stop(reason: params["reason"] as? String ?? "realtime_closed")
        case "item/completed":
            if let item = params["item"] as? [String: Any] {
                _ = inspectEmbodimentMCPItem(item, emitDiagnostic: true)
            }
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String,
                  !turnID.isEmpty else { return }
            currentBackingTurnID = turnID
            backingTurnSequenceByID[turnID] = participantTurnSequence
            emitter.emit("backing_turn_started", fields: [
                "turn_id": String(turnID.prefix(128)),
                "turn_sequence": participantTurnSequence,
            ])
            interruptBackingTurnIfOwnedByExternalWork()
        case "turn/completed":
            handleCompletedTurn(params)
        default:
            break
        }
    }

    private func handleCompletedTurn(_ params: [String: Any]) {
        guard let turn = params["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty else { return }
        if currentBackingTurnID == turnID {
            currentBackingTurnID = nil
        }
        let sequence = backingTurnSequenceByID.removeValue(forKey: turnID)
            ?? participantTurnSequence
        guard !handledBackingTurnIDs.contains(turnID),
              !pendingBackingTurnHydrationIDs.contains(turnID) else { return }
        let status = LiveVoiceBackingTurnStatus(protocolValue: turn["status"] as? String)
        let errorMessage = (turn["error"] as? [String: Any])?["message"] as? String
        let items = turn["items"] as? [[String: Any]] ?? []
        let itemsView = turn["itemsView"] as? String
        if itemsView != "full" && (itemsView != nil || items.isEmpty) {
            hydrateCompletedTurn(
                turnID: turnID,
                sequence: sequence,
                status: status,
                errorMessage: errorMessage,
                fallbackItems: items
            )
            return
        }
        processCompletedTurn(
            turnID: turnID,
            sequence: sequence,
            status: status,
            errorMessage: errorMessage,
            items: items
        )
    }

    private func hydrateCompletedTurn(
        turnID: String,
        sequence: UInt64,
        status: LiveVoiceBackingTurnStatus,
        errorMessage: String?,
        fallbackItems: [[String: Any]]
    ) {
        guard let threadID else {
            processCompletedTurn(
                turnID: turnID,
                sequence: sequence,
                status: status,
                errorMessage: errorMessage,
                items: fallbackItems
            )
            return
        }
        pendingBackingTurnHydrationIDs.insert(turnID)
        let fallback = JSONDictionary(value: ["items": fallbackItems])
        connection.request(
            method: "thread/items/list",
            params: [
                "threadId": threadID,
                "turnId": turnID,
                "limit": 200,
                "sortDirection": "asc",
            ],
            timeoutMilliseconds: 2_000
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBackingTurnHydrationIDs.remove(turnID)
                let result = response.value["result"] as? [String: Any]
                let entries = result?["data"] as? [[String: Any]] ?? []
                let hydratedItems = entries.compactMap { $0["item"] as? [String: Any] }
                self.emitter.emit("backing_turn_hydrated", fields: [
                    "turn_id": String(turnID.prefix(128)),
                    "turn_sequence": sequence,
                    "item_count": hydratedItems.count,
                    "fallback_used": hydratedItems.isEmpty,
                ])
                let fallbackItems = fallback.value["items"] as? [[String: Any]] ?? []
                self.processCompletedTurn(
                    turnID: turnID,
                    sequence: sequence,
                    status: status,
                    errorMessage: errorMessage,
                    items: hydratedItems.isEmpty ? fallbackItems : hydratedItems
                )
            }
        }
    }

    private func processCompletedTurn(
        turnID: String,
        sequence: UInt64,
        status: LiveVoiceBackingTurnStatus,
        errorMessage: String?,
        items: [[String: Any]]
    ) {
        guard handledBackingTurnIDs.insert(turnID).inserted else { return }
        handledBackingTurnOrder.append(turnID)
        if handledBackingTurnOrder.count > 256 {
            for expired in handledBackingTurnOrder.prefix(64) {
                handledBackingTurnIDs.remove(expired)
            }
            handledBackingTurnOrder.removeFirst(64)
        }
        guard sequence == participantTurnSequence else {
            emitter.emit("backing_turn_response_held", fields: [
                "turn_id": String(turnID.prefix(128)),
                "turn_sequence": sequence,
                "current_sequence": participantTurnSequence,
                "reason": "participant_turn_advanced",
            ])
            return
        }
        let assistantSpeechObserved = assistantSpeechObservedSequences.contains(sequence)
        var successfulHermesDelegation = false
        var authorizationFailure: MCPToolCompletionDiagnostic?
        for item in items where item["type"] as? String == "mcpToolCall" {
            if let diagnostic = MCPToolCompletionDiagnostic.parse(item),
               diagnostic.isAuthorizationFailure {
                authorizationFailure = diagnostic
            }
            successfulHermesDelegation = inspectEmbodimentMCPItem(
                item,
                emitDiagnostic: true
            ) || successfulHermesDelegation
        }
        let agentMessages = items.filter { $0["type"] as? String == "agentMessage" }
        let agentMessage = agentMessages.reversed().first { item in
            item["phase"] as? String == "final_answer"
        }?["text"] as? String ?? agentMessages.last?["text"] as? String
        let normalizedAgentMessage = agentMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let managedResponse = normalizedAgentMessage?.isEmpty == false
            ? normalizedAgentMessage
            : authorizationFailure.map { _ in
                MCPToolAuthorizationFailureResponse.phrase(languageTag: preferredLanguageTag)
            }
        let workItemTypes: Set<String> = [
            "mcpToolCall", "commandExecution", "fileChange", "dynamicToolCall",
            "functionCallOutput", "collabAgentToolCall",
        ]
        let containsAuthoritativeBackingWork = items.contains {
            guard let type = $0["type"] as? String else { return false }
            return workItemTypes.contains(type)
        }
        let itemFailed = items.contains { item in
            guard let itemStatus = item["status"] as? String else { return false }
            return itemStatus == "failed" || itemStatus == "declined"
        }
        let effectiveStatus: LiveVoiceBackingTurnStatus =
            status == .completed && itemFailed ? .failed : status
        switch LiveVoiceHandoffResponsePolicy.disposition(
            hasAgentMessage: managedResponse?.isEmpty == false,
            realtimeResponseSpoken: assistantSpeechObserved,
            successfulExternalDelegation: successfulHermesDelegation,
            containsAuthoritativeBackingWork: containsAuthoritativeBackingWork,
            turnStatus: effectiveStatus
        ) {
        case .appendFinalSpeech:
            if let managedResponse {
                appendManagedHandoffSpeech(
                    managedResponse,
                    sequence: sequence,
                    kind: authorizationFailure == nil ? "backing_final" : "authorization_denial"
                )
                if authorizationFailure != nil, normalizedAgentMessage?.isEmpty != false {
                    emitter.emit("managed_authorization_denial_spoken", fields: [
                        "tool": authorizationFailure?.tool ?? "unknown",
                    ])
                }
            }
        case .retainExistingRealtimeResponse:
            cancelResponseDeadline(for: sequence)
            emitter.emit("managed_handoff_response_held", fields: [
                "reason": "realtime_response_already_spoken",
                "turn_sequence": sequence,
            ])
        case .externalDelegationOwnsResponse:
            cancelResponseDeadline(for: sequence)
        case let .appendRecoverySpeech(kind):
            let recovery = authorizationFailure.map { _ in
                MCPToolAuthorizationFailureResponse.phrase(languageTag: preferredLanguageTag)
            } ?? LiveVoiceTurnRecoveryResponse.phrase(
                kind: kind,
                languageTag: preferredLanguageTag
            )
            appendManagedHandoffSpeech(
                recovery,
                sequence: sequence,
                kind: "recovery_\(String(describing: kind))"
            )
        }
        emitter.emit("backing_turn_completed", fields: [
            "turn_id": String(turnID.prefix(128)),
            "turn_sequence": sequence,
            "status": effectiveStatus.rawValue,
            "item_count": items.count,
            "authoritative_work": containsAuthoritativeBackingWork,
            "error": String((errorMessage ?? "").prefix(256)),
        ])
    }

    private func interruptBackingTurnIfOwnedByExternalWork() {
        guard externalWorkResponseOwnerSequence == participantTurnSequence,
              let threadID,
              let turnID = currentBackingTurnID else { return }
        currentBackingTurnID = nil
        connection.request(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                if response.value["error"] == nil {
                    self.emitter.emit("backing_turn_interrupted", fields: [
                        "turn_id": String(turnID.prefix(128)),
                        "response_owner": "l1_external_work",
                    ])
                } else {
                    self.emitter.emit("backing_turn_interrupt_rejected", fields: [
                        "turn_id": String(turnID.prefix(128)),
                        "reason": AppServerConnection.responseMessage(response.value),
                    ])
                }
            }
        }
    }

    private func appendManagedHandoffSpeech(
        _ text: String,
        sequence: UInt64,
        kind: String,
        attempt: Int = 0,
        taskID: String? = nil,
        successEvent: String = "managed_handoff_response_spoken",
        failureEvent: String = "managed_handoff_response_rejected"
    ) {
        guard !text.isEmpty,
              sequence == participantTurnSequence,
              !managedResponseDeliveredSequences.contains(sequence) else { return }
        guard let threadID else {
            emitter.emit(failureEvent, fields: [
                "reason": "live_voice_thread_unavailable",
                "turn_sequence": sequence,
                "kind": kind,
            ])
            fail(LiveVoiceError.appServerResponse("live_voice_thread_unavailable"))
            return
        }
        if attempt == 0 {
            guard managedResponseInFlightSequences.insert(sequence).inserted else { return }
        }
        connection.request(
            method: "thread/realtime/appendSpeech",
            params: [
                "threadId": threadID,
                "text": String(text.prefix(8_192)),
            ],
            timeoutMilliseconds: 2_000
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                let taskFields: [String: Any] = taskID.map { ["task_id": $0] } ?? [:]
                guard sequence == self.participantTurnSequence else {
                    self.managedResponseInFlightSequences.remove(sequence)
                    self.emitter.emit("managed_handoff_response_held", fields: [
                        "turn_sequence": sequence,
                        "kind": kind,
                        "reason": "participant_turn_advanced",
                    ])
                    return
                }
                if response.value["error"] == nil {
                    self.managedResponseInFlightSequences.remove(sequence)
                    self.managedResponseDeliveredSequences.insert(sequence)
                    self.cancelResponseDeadline(for: sequence)
                    self.emitter.emit(successEvent, fields: taskFields.merging([
                        "turn_sequence": sequence,
                        "kind": kind,
                        "attempt": attempt + 1,
                    ]) { _, new in new })
                } else if attempt == 0, sequence == self.participantTurnSequence {
                    self.emitter.emit("managed_handoff_response_retrying", fields: [
                        "turn_sequence": sequence,
                        "kind": kind,
                        "reason": AppServerConnection.responseMessage(response.value),
                    ])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.appendManagedHandoffSpeech(
                            text,
                            sequence: sequence,
                            kind: kind,
                            attempt: 1,
                            taskID: taskID,
                            successEvent: successEvent,
                            failureEvent: failureEvent
                        )
                    }
                } else {
                    self.managedResponseInFlightSequences.remove(sequence)
                    self.emitter.emit(failureEvent, fields: taskFields.merging([
                        "reason": AppServerConnection.responseMessage(response.value),
                        "turn_sequence": sequence,
                        "kind": kind,
                    ]) { _, new in new })
                    self.fail(LiveVoiceError.appServerResponse(
                        AppServerConnection.responseMessage(response.value)
                    ))
                }
            }
        }
    }

    private func armResponseDeadline(for sequence: UInt64) {
        responseDeadlineWorkItem?.cancel()
        responseDeadlineSequence = sequence
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.stopping,
                  self.responseDeadlineSequence == sequence,
                  self.participantTurnSequence == sequence,
                  !self.assistantSpeechObservedSequences.contains(sequence),
                  !self.managedResponseDeliveredSequences.contains(sequence),
                  !self.managedResponseInFlightSequences.contains(sequence),
                  self.externalWorkResponseOwnerSequence != sequence else { return }
            self.responseDeadlineWorkItem = nil
            self.responseDeadlineSequence = nil
            self.emitter.emit("response_deadline_expired", fields: [
                "turn_sequence": sequence,
                "deadline_ms": 20_000,
            ])
            let recovery = LiveVoiceTurnRecoveryResponse.phrase(
                kind: .timedOut,
                languageTag: self.preferredLanguageTag
            )
            if let threadID = self.threadID,
               let turnID = self.currentBackingTurnID,
               self.backingTurnSequenceByID[turnID] == sequence {
                self.currentBackingTurnID = nil
                self.connection.request(
                    method: "turn/interrupt",
                    params: ["threadId": threadID, "turnId": turnID],
                    timeoutMilliseconds: 1_500
                ) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.appendManagedHandoffSpeech(
                            recovery,
                            sequence: sequence,
                            kind: "recovery_timedOut"
                        )
                    }
                }
            } else {
                self.appendManagedHandoffSpeech(
                    recovery,
                    sequence: sequence,
                    kind: "recovery_timedOut"
                )
            }
        }
        responseDeadlineWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelResponseDeadline(for sequence: UInt64) {
        guard responseDeadlineSequence == sequence else { return }
        responseDeadlineWorkItem?.cancel()
        responseDeadlineWorkItem = nil
        responseDeadlineSequence = nil
    }

    /// App Server emits tool completion before the enclosing turn completes.
    /// Logging the item immediately preserves the actual MCP failure instead
    /// of relying on the assistant's later natural-language interpretation.
    private func inspectEmbodimentMCPItem(
        _ item: [String: Any],
        emitDiagnostic: Bool
    ) -> Bool {
        guard let diagnostic = MCPToolCompletionDiagnostic.parse(item) else { return false }
        let itemID = diagnostic.itemID
        let shouldEmit: Bool
        if let itemID, !itemID.isEmpty {
            shouldEmit = reportedEmbodimentMCPItemIDs.insert(itemID).inserted
            if reportedEmbodimentMCPItemIDs.count > 128 {
                reportedEmbodimentMCPItemIDs.removeAll(keepingCapacity: true)
                reportedEmbodimentMCPItemIDs.insert(itemID)
            }
        } else {
            shouldEmit = true
        }
        if emitDiagnostic, shouldEmit {
            emitter.emit("embodiment_mcp_call", fields: [
                "tool": diagnostic.tool,
                "status": diagnostic.effectiveStatus,
                "protocol_status": diagnostic.protocolStatus,
                "error": diagnostic.error,
                "item_id": String((itemID ?? "").prefix(128)),
            ])
        }
        return diagnostic.tool == "delegate_hermes_task" && diagnostic.succeeded
    }

    private func handleRealtimeDataChannel(_ payload: String) {
        guard payload.utf8.count <= 1_048_576,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if observedRealtimeEventTypes.count < 32,
           observedRealtimeEventTypes.insert(type).inserted {
            emitter.emit("realtime_event_type", fields: ["type": String(type.prefix(128))])
        }
        if type == "session.started" || type == "session.created" || type == "session.updated" {
            realtimeSessionInitialized = true
            emitter.emit("realtime_session_configuration", fields: [
                "source_event": type,
                "interrupt_response": Self.interruptResponseState(in: object),
                "session_keys": Self.sessionKeys(in: object),
            ])
            if type == "session.updated", Self.interruptResponseEnabled(in: object) {
                if !naturalTurnTakingConfirmed {
                    naturalTurnTakingConfirmed = true
                    emitter.emit("natural_turn_taking_confirmed")
                }
            }
            activateIfReady()
            return
        }
        if type == "error" {
            let error = object["error"] as? [String: Any]
            let eventID = (object["event_id"] as? String) ?? "unknown"
            if eventID.hasPrefix("soma_"), eventID.hasSuffix("_response_cancel") {
                if let episodeID = Self.visualEpisodeID(
                    from: eventID,
                    suffix: "_response_cancel"
                ) {
                    observeVisualCancellationSettled(episodeID: episodeID)
                }
                emitter.emit("visual_turn_barrier", fields: [
                    "state": "cancel_not_required",
                    "task_id": visualResponseBarrier?.episodeID.uuidString.lowercased() ?? "unknown",
                    "reason": String(((error?["code"] as? String) ?? "no_active_response").prefix(128)),
                ])
                return
            }
            if eventID.hasPrefix("soma_"), eventID.hasSuffix("_output_audio_buffer_clear") {
                emitter.emit("visual_turn_barrier", fields: [
                    "state": "audio_clear_not_required",
                    "task_id": visualResponseBarrier?.episodeID.uuidString.lowercased() ?? "unknown",
                    "reason": String(((error?["code"] as? String) ?? "no_audio_to_clear").prefix(128)),
                ])
                return
            }
            if eventID.hasPrefix("soma_"), eventID.hasSuffix("_response_create") {
                fail(LiveVoiceError.webRTC(
                    "visual_response_create_failed: \((error?["message"] as? String) ?? "unknown")"
                ))
                return
            }
            emitter.emit("realtime_protocol_error", fields: [
                "event_id": String(eventID.prefix(128)),
                "code": String(((error?["code"] as? String) ?? "unknown").prefix(128)),
                "message": String(((error?["message"] as? String) ?? "unknown").prefix(256)),
            ])
            return
        }
        if type.contains("speech_started") {
            participantAudioEpoch &+= 1
            observeInputSpeechStarted()
            return
        }
        if LiveVoiceRealtimeEventSemantics.confirmsParticipantInput(type: type) {
            observeInputSpeechStarted()
        }
        if type.contains("speech_stopped") {
            inputSpeechInProgress = false
            return
        }
        if type.contains("response.cancelled") || type.contains("response.canceled") {
            selectedAudioOutput?.flush()
            let responseID = Self.realtimeResponseID(in: object)
            observeVisualResponseEnded(responseID: responseID)
            emitter.emit("response_interrupted")
            return
        }
        if type == "output_audio_buffer.started" || type.contains("response.output_audio.delta") {
            if observeVisualPresentationStarted(responseID: Self.realtimeResponseID(in: object)) {
                return
            }
            observeAssistantOutputStarted()
            return
        }
        if type == "output_audio_buffer.stopped" {
            observeAssistantOutputEnded()
            return
        }
        if type == "output_audio_buffer.cleared" || type.contains("conversation.item.truncated") {
            selectedAudioOutput?.flush()
            observeAssistantOutputEnded()
            emitter.emit("interrupted_audio_cleared", fields: ["type": String(type.prefix(128))])
            return
        }
        if type == "conversation.item.input_audio_transcription.delta" ||
            type == "input_transcript.delta" {
            guard let delta = (object["delta"] as? String) ?? (object["text"] as? String),
                  !delta.isEmpty else { return }
            observeInputSpeechStarted()
            partialUserTranscript = String((partialUserTranscript + delta).prefix(4_096))
            emitter.emit("transcript_partial", fields: [
                "thread_id": threadID ?? "",
                "text": partialUserTranscript,
            ])
            return
        }
        if type == "conversation.item.input_audio_transcription.completed" ||
            type == "input_transcript.completed" {
            if let transcript = LiveVoiceWireTranscriptParser.parse(object) {
                acceptWireParticipantTranscript(transcript)
                return
            }
            let text = (object["transcript"] as? String) ?? (object["text"] as? String) ?? ""
            guard !text.isEmpty else { return }
            acceptWireParticipantTranscript(.init(
                text: text,
                itemID: (object["item_id"] as? String) ?? (object["itemId"] as? String),
                turnID: (object["turn_id"] as? String) ?? (object["turnId"] as? String),
                source: .inputTranscript,
                authoritative: true
            ))
            return
        }
        if type == "input_transcript.added" {
            guard let transcript = LiveVoiceWireTranscriptParser.parse(object) else { return }
            observeWireParticipantTranscriptDelta(transcript)
            return
        }
        if type == "delegation.created" {
            guard let transcript = LiveVoiceWireTranscriptParser.parse(object) else {
                let item = object["item"] as? [String: Any]
                emitter.emit("input_transcript_authority_missing", fields: [
                    "event_keys": object.keys.sorted().joined(separator: ","),
                    "item_keys": item?.keys.sorted().joined(separator: ",") ?? "none",
                ])
                return
            }
            acceptWireParticipantTranscript(transcript)
            return
        }
        if type == "conversation.item.input_audio_transcription.failed" ||
            type == "input_transcript.failed" {
            let error = object["error"] as? [String: Any]
            emitter.emit("input_transcription_failed", fields: [
                "reason": String(((error?["message"] as? String) ?? "realtime_input_transcription_failed").prefix(256)),
            ])
            return
        }
        if type == "turn.created" || type.contains("response.created") {
            let responseID = Self.realtimeResponseID(in: object)
            currentRealtimeResponseID = responseID
            if observeVisualResponseStarted(responseID: responseID) { return }
            emitter.emit("response_preparing")
            return
        }
        if type == "turn.completed" || type == "turn.finished" || type == "turn.done" ||
            type.contains("response.completed") || type.contains("response.done") {
            let responseID = Self.realtimeResponseID(in: object)
            if currentRealtimeResponseID == responseID { currentRealtimeResponseID = nil }
            if let barrier = visualResponseBarrier,
               barrier.ownsReplacementResponse(responseID) {
                if barrier.presentationReleased {
                    completeCurrentVisualResponse()
                } else {
                    fail(LiveVoiceError.webRTC(
                        "visual_replacement_ended_without_audio_presentation"
                    ))
                    return
                }
            } else {
                observeVisualResponseEnded(responseID: responseID)
            }
            setCognitiveTurn(active: false)
            scheduleAssistantOutputEnd(after: 0.35)
            emitter.emit("response_completed")
            if let taskID = pendingHermesReportTaskID {
                pendingHermesReportTaskID = nil
                emitter.emit("hermes_task_result_accepted", fields: ["task_id": taskID])
            }
        }
    }

    private func observeInputSpeechStarted() {
        guard !inputSpeechInProgress else { return }
        setCognitiveTurn(active: true)
        inputSpeechInProgress = true
        emitter.emit("input_speech_started")
    }

    private func observeWireParticipantTranscriptDelta(_ transcript: LiveVoiceWireTranscript) {
        guard !transcript.authoritative else {
            acceptWireParticipantTranscript(transcript)
            return
        }
        emitter.emit("transcript_partial", fields: [
            "thread_id": threadID ?? "",
            "text": transcript.text,
            "item_id": transcript.itemID ?? "",
            "source": transcript.source.rawValue,
        ])
    }

    private func acceptWireParticipantTranscript(_ transcript: LiveVoiceWireTranscript) {
        guard transcript.authoritative else {
            observeWireParticipantTranscriptDelta(transcript)
            return
        }
        if transcript.source == .delegation,
           let prior = lastWireParticipantTranscript,
           prior.epoch == participantAudioEpoch,
           ((transcript.turnID != nil && prior.turnID == transcript.turnID)
                || prior.text == transcript.text) {
            if prior.text != transcript.text {
                emitter.emit("input_transcript_reconciled", fields: [
                    "turn_id": transcript.turnID ?? "unknown",
                    "prior_characters": prior.text.count,
                    "authoritative_characters": transcript.text.count,
                ])
            }
            return
        }
        emitter.emit("input_transcript_ready", fields: [
            "characters": min(transcript.text.count, 65_535),
            "source": transcript.source.rawValue,
            "authoritative": transcript.authoritative,
        ])
        lastWireParticipantTranscript = (
            transcript.text,
            transcript.turnID,
            participantAudioEpoch
        )
        emitFinalizedTranscript(
            role: "user",
            text: transcript.text,
            itemID: transcript.itemID,
            origin: .realtimeWire
        )
    }

    private func emitFinalizedTranscript(
        role: String,
        text: String,
        itemID: String?,
        origin: FinalizedTranscriptOrigin = .realtimeWire
    ) {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedText.isEmpty else { return }

        if role == "user",
           origin == .appServer,
           let lastWireParticipantTranscript,
           lastWireParticipantTranscript.epoch == participantAudioEpoch,
           lastWireParticipantTranscript.text == normalizedText {
            return
        }

        if let itemID, !itemID.isEmpty {
            guard finalizedTranscriptItemIDs.insert(itemID).inserted else { return }
            finalizedTranscriptItemOrder.append(itemID)
            if finalizedTranscriptItemOrder.count > 128 {
                let excess = finalizedTranscriptItemOrder.count - 128
                let expired = Array(finalizedTranscriptItemOrder.prefix(excess))
                finalizedTranscriptItemOrder.removeFirst(excess)
                for value in expired { finalizedTranscriptItemIDs.remove(value) }
            }
        } else {
            let nowNS = DispatchTime.now().uptimeNanoseconds
            if let lastFallbackTranscript,
               lastFallbackTranscript.role == role,
               lastFallbackTranscript.text == normalizedText,
               nowNS >= lastFallbackTranscript.atNS,
               nowNS - lastFallbackTranscript.atNS <= 2_000_000_000 {
                return
            }
            lastFallbackTranscript = (role, normalizedText, nowNS)
        }

        if role == "assistant",
           let barrier = visualResponseBarrier,
           barrier.suppressesAssistantPresentation {
            emitter.emit("visual_turn_barrier", fields: [
                "state": "provisional_transcript_suppressed",
                "task_id": barrier.episodeID.uuidString.lowercased(),
                "reason": "fresh_evidence_not_committed",
            ])
            return
        }

        if role == "user" {
            participantTurnSequence &+= 1
            if participantTurnSequence > 64 {
                let minimumRetainedSequence = participantTurnSequence - 64
                assistantSpeechObservedSequences = assistantSpeechObservedSequences.filter {
                    $0 >= minimumRetainedSequence
                }
                managedResponseInFlightSequences = managedResponseInFlightSequences.filter {
                    $0 >= minimumRetainedSequence
                }
                managedResponseDeliveredSequences = managedResponseDeliveredSequences.filter {
                    $0 >= minimumRetainedSequence
                }
                backingTurnSequenceByID = backingTurnSequenceByID.filter {
                    $0.value >= minimumRetainedSequence
                }
            }
            responseDeadlineWorkItem?.cancel()
            responseDeadlineWorkItem = nil
            responseDeadlineSequence = nil
            if let externalWorkResponseOwnerSequence,
               externalWorkResponseOwnerSequence != participantTurnSequence {
                self.externalWorkResponseOwnerSequence = nil
            }
            if let currentBackingTurnID,
               backingTurnSequenceByID[currentBackingTurnID] == 0 {
                backingTurnSequenceByID[currentBackingTurnID] = participantTurnSequence
            }
            latestParticipantTranscript = normalizedText
            if conversationControlClassifier.classify(normalizedText) == .endConversation {
                emitter.emit("transcript_finalized", fields: [
                    "thread_id": threadID ?? "",
                    "role": role,
                    "text": String(normalizedText.prefix(8_192)),
                ])
                emitter.emit("conversation_control_applied", fields: [
                    "control": "end_conversation",
                    "source": "final_participant_transcript",
                ])
                stop(reason: "participant_requested_end")
                return
            }
            if L1LiveEpistemicReflexRouter.requiresCurrentCameraEvidence(
                transcript: normalizedText
            ) {
                beginCurrentVisualTurn(
                    episodeID: UUID(),
                    participantTurnSequence: participantTurnSequence,
                    transcript: normalizedText,
                    source: "deterministic_current_view_intent"
                )
            } else if let barrier = visualResponseBarrier {
                if barrier.presentationReleased {
                    completeCurrentVisualResponse()
                } else {
                    fail(LiveVoiceError.webRTC("visual_turn_interrupted_by_new_participant_turn"))
                    return
                }
            }
            armResponseDeadline(for: participantTurnSequence)
        }

        emitter.emit("transcript_finalized", fields: [
            "thread_id": threadID ?? "",
            "role": role,
            "text": String(normalizedText.prefix(8_192)),
        ])
        if role == "user" {
            inputSpeechInProgress = false
            partialUserTranscript = ""
        } else {
            scheduleAssistantOutputEnd(after: 0.35)
        }
    }

    private func observeAssistantOutputStarted() {
        assistantSpeechObservedSequences.insert(participantTurnSequence)
        cancelResponseDeadline(for: participantTurnSequence)
        assistantOutputEndWorkItem?.cancel()
        assistantOutputEndWorkItem = nil
        guard !assistantOutputActive else { return }
        assistantOutputActive = true
        selectedAudioOutput?.beginSpeech()
        emitter.emit("output_speech_started")
    }

    private func observeAssistantOutputEnded() {
        assistantOutputEndWorkItem?.cancel()
        assistantOutputEndWorkItem = nil
        guard assistantOutputActive else { return }
        assistantOutputActive = false
        selectedAudioOutput?.finishSpeech()
        emitter.emit("output_speech_ended")
        if let reason = pendingTransportClosureReason {
            pendingTransportClosureReason = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !stopping else { return }
                stop(reason: reason)
            }
        }
    }

    private func noteAssistantAudioActivity() {
        guard assistantOutputActive else { return }
        scheduleAssistantOutputEnd(after: 0.8)
    }

    private func scheduleAssistantOutputEnd(after delay: TimeInterval) {
        guard assistantOutputActive else { return }
        assistantOutputEndWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping else { return }
            self.assistantOutputEndWorkItem = nil
            self.observeAssistantOutputEnded()
        }
        assistantOutputEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func routeAssistantPCM(_ chunk: AssistantPCMChunk) {
        guard LiveVoicePlaybackOwnershipPolicy.disposition(
            for: chunk.source
        ).rendersToSpeaker else { return }
        if let audioPlayoutSource {
            guard audioPlayoutSource == chunk.source else { return }
            playAssistantPCM(chunk)
            return
        }
        selectAudioPlayoutSource(.webRTCPlayback)
        playAssistantPCM(chunk)
    }

    private func selectAudioPlayoutSource(_ source: LiveVoicePlaybackReferenceSource) {
        guard audioPlayoutSource == nil else { return }
        audioPlayoutSource = source
        emitter.emit("audio_playout_source_selected", fields: ["source": source.rawValue])
    }

    private nonisolated static func appServerAudioChunk(
        from params: [String: Any]
    ) -> AssistantPCMChunk? {
        guard let audio = params["audio"] as? [String: Any],
              let encoded = audio["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let sampleRate = (audio["sampleRate"] as? NSNumber)?.intValue,
              (8_000...96_000).contains(sampleRate),
              let channels = (audio["numChannels"] as? NSNumber)?.intValue,
              (1...8).contains(channels) else { return nil }
        let encodedSamples = data.count / (channels * 2)
        let declaredSamples = (audio["samplesPerChannel"] as? NSNumber)?.intValue
        let samplesPerChannel = declaredSamples ?? encodedSamples
        guard samplesPerChannel > 0,
              samplesPerChannel <= 65_536,
              data.count == samplesPerChannel * channels * 2 else { return nil }
        return AssistantPCMChunk(
            data: data,
            encoded: encoded,
            sampleRate: sampleRate,
            channels: channels,
            samplesPerChannel: samplesPerChannel,
            source: .appServer
        )
    }

    private func playAssistantPCM(_ chunk: AssistantPCMChunk) {
        do {
            try selectedAudioOutput?.enqueuePCM16(
                chunk.data,
                sampleRate: Double(chunk.sampleRate),
                channels: chunk.channels,
                samplesPerChannel: chunk.samplesPerChannel
            )
        } catch {
            fail(error)
            return
        }
        if !voiceMode.requiresProcessedPlayback {
            forwardAssistantReference(chunk)
        }
    }

    private func forwardAssistantReference(_ chunk: AssistantPCMChunk) {
        emitter.emit("assistant_output_reference", fields: [
            "data": chunk.encoded,
            "sample_rate": chunk.sampleRate,
            "samples_per_channel": chunk.samplesPerChannel,
            "num_channels": chunk.channels,
            "source": chunk.source.rawValue,
            "reset_reference": false,
        ])
    }

    private func forwardRenderedAssistantReference(_ rendered: SelectedAudioOutput.RenderedPCM) {
        emitter.emit("assistant_output_reference", fields: [
            "data": rendered.data.base64EncodedString(),
            "sample_rate": rendered.sampleRate,
            "samples_per_channel": rendered.samplesPerChannel,
            "num_channels": rendered.channels,
            "source": LiveVoicePlaybackReferenceSource.webRTCPlayback.rawValue,
            "reset_reference": false,
        ])
    }

    private func setCognitiveTurn(active: Bool) {
        guard cognitiveTurnOpen != active,
              let embodimentSocketURL,
              let sessionCapability,
              !sessionCapability.isEmpty else { return }
        let kind: EmbodimentIPCCommandKind = active ? .cognitiveTurnStarted : .cognitiveTurnEnded
        do {
            let reply = try EmbodimentShadowSocketClient.send(
                .init(kind: kind, sessionAuthorization: sessionCapability),
                socketURL: embodimentSocketURL
            )
            guard reply.ok else {
                emitter.emit("cognitive_turn_binding_failed", fields: [
                    "reason": String((reply.error ?? "authorization_failed").prefix(192)),
                ])
                return
            }
            cognitiveTurnOpen = active
            emitter.emit(active ? "cognitive_turn_started" : "cognitive_turn_ended")
        } catch {
            emitter.emit("cognitive_turn_binding_failed", fields: [
                "reason": String(error.localizedDescription.prefix(192)),
            ])
        }
    }

    private static func interruptResponseEnabled(in event: [String: Any]) -> Bool {
        guard let session = event["session"] as? [String: Any] else { return false }
        if let audio = session["audio"] as? [String: Any],
           let input = audio["input"] as? [String: Any],
           let turnDetection = input["turn_detection"] as? [String: Any],
           turnDetection["interrupt_response"] as? Bool == true {
            return true
        }
        if let turnDetection = session["turn_detection"] as? [String: Any],
           turnDetection["interrupt_response"] as? Bool == true {
            return true
        }
        return false
    }

    private static func interruptResponseState(in event: [String: Any]) -> String {
        guard let session = event["session"] as? [String: Any] else { return "missing_session" }
        if let audio = session["audio"] as? [String: Any],
           let input = audio["input"] as? [String: Any],
           let turnDetection = input["turn_detection"] as? [String: Any],
           let value = turnDetection["interrupt_response"] as? Bool {
            return value ? "true" : "false"
        }
        if let turnDetection = session["turn_detection"] as? [String: Any],
           let value = turnDetection["interrupt_response"] as? Bool {
            return value ? "true" : "false"
        }
        return "missing"
    }

    private static func sessionKeys(in event: [String: Any]) -> String {
        guard let session = event["session"] as? [String: Any] else { return "" }
        return String(session.keys.sorted().joined(separator: ",").prefix(512))
    }

    private static func realtimeResponseID(in event: [String: Any]) -> String? {
        let directKeys = ["response_id", "responseId", "turn_id", "turnId"]
        for key in directKeys {
            if let value = event[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(value.prefix(256))
            }
        }
        for containerKey in ["response", "turn"] {
            if let container = event[containerKey] as? [String: Any],
               let value = container["id"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(value.prefix(256))
            }
        }
        return nil
    }

    private static func visualEpisodeID(from eventID: String, suffix: String) -> UUID? {
        guard eventID.hasPrefix("soma_"), eventID.hasSuffix(suffix) else { return nil }
        let start = eventID.index(eventID.startIndex, offsetBy: "soma_".count)
        let end = eventID.index(eventID.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return UUID(uuidString: String(eventID[start..<end]))
    }

    private func activateIfReady() {
        guard !activeEmitted,
              startRequestAccepted,
              appServerStarted,
              webRTCConnected,
              realtimeSessionInitialized else { return }
        activeEmitted = true
        emitter.emit("active", fields: ["thread_id": threadID ?? ""])
        triggerProactiveOpeningIfNeeded()
    }

    /// Realtime sessions do not generate a turn from developer context alone.
    /// The transport role is user because that is the app-server turn trigger;
    /// its payload is a language-neutral control envelope, never a synthetic
    /// English user utterance.
    private func triggerProactiveOpeningIfNeeded() {
        guard let threadID,
              let opening = proactiveOpeningText,
              let trigger = LiveVoiceOpeningControllerEvent.make(
                  opening: opening,
                  languageTag: preferredLanguageTag,
                  voiceMode: voiceMode
              ) else { return }
        proactiveOpeningText = nil
        connection.request(
            method: "thread/realtime/appendText",
            params: [
                "threadId": threadID,
                "text": String(trigger.prefix(1_024)),
                "role": "user",
            ]
        ) { [weak self] response in
            guard response.value["error"] == nil else {
                DispatchQueue.main.async {
                    self?.fail(LiveVoiceError.appServerResponse(
                        AppServerConnection.responseMessage(response.value)
                    ))
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.emitter.emit("proactive_opening_triggered")
            }
        }
    }

    private func fail(_ error: Error) {
        emitter.emit("failed", fields: ["reason": String(error.localizedDescription.prefix(256))])
        stop(reason: "failed", emitEnded: false)
    }

    private func scheduleTransportClosure(reason: String) {
        guard pendingTransportClosureReason == nil else { return }
        if assistantOutputActive {
            pendingTransportClosureReason = reason
            emitter.emit("transport_draining", fields: [
                "reason": String(reason.prefix(128)),
                "audio_output_active": true,
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !stopping,
                      pendingTransportClosureReason == reason else { return }
                pendingTransportClosureReason = nil
                stop(reason: reason)
            }
            return
        }
        emitter.emit("transport_closing", fields: [
            "reason": String(reason.prefix(128)),
            "audio_output_active": false,
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !stopping else { return }
            stop(reason: reason)
        }
    }

    private func stop(reason: String, emitEnded: Bool = true) {
        guard !stopping else { return }
        stopping = true
        pendingTransportClosureReason = nil
        assistantOutputEndWorkItem?.cancel()
        assistantOutputEndWorkItem = nil
        embodimentMCPVerificationTimeoutWorkItem?.cancel()
        embodimentMCPVerificationTimeoutWorkItem = nil
        responseDeadlineWorkItem?.cancel()
        responseDeadlineWorkItem = nil
        responseDeadlineSequence = nil
        cancelVisualTurnTimeouts()
        partialUserTranscript = ""
        currentRealtimeResponseID = nil
        visualResponseBarrier = nil
        deferredVisualEvidenceEpisodeID = nil
        setVisualOutputGate(closed: false, resetPresentation: true)
        observeAssistantOutputEnded()
        setCognitiveTurn(active: false)
        if let threadID {
            connection.request(method: "thread/realtime/stop", params: ["threadId": threadID]) { _ in }
        }
        webView.evaluateJavaScript("void stopWebRTC()")
        selectedAudioOutput?.stop()
        connection.stop()
        if emitEnded { emitter.emit("ended", fields: ["reason": String(reason.prefix(128))]) }
        NSApplication.shared.terminate(nil)
    }

    private static func codexURL() -> URL? {
        SOMACodexLocator.locate()?.executableURL
    }

    private static func validCameraImageDataURI(_ value: String) -> Bool {
        guard value.hasPrefix("data:image/jpeg;base64,") else { return false }
        let encoded = value.dropFirst("data:image/jpeg;base64,".count)
        return !encoded.isEmpty && encoded.count <= 4 * 1_048_576
    }

    private static let webRTCHTML = """
    <!doctype html><html><body><script>
    let peer = null;
    let stream = null;
    let channel = null;
    let inputContext = null;
    let inputDestination = null;
    let inputWorklet = null;
    let outputContext = null;
    let outputWorklet = null;
    let outputGate = null;
    let visualOutputGateClosed = false;
    let outputSpeaking = false;
    let outputAboveCount = 0;
    let outputBelowCount = 0;
    function send(event, extra = {}) {
      window.webkit.messageHandlers.soma.postMessage(Object.assign({event}, extra));
    }
    async function startWebRTC(
      outputDeviceName = '',
      useSystemDefault = true,
      useVoiceEffects = false,
      voiceEffectProfile = {}
    ) {
      try {
        inputContext = new AudioContext();
        await inputContext.resume();
        const processorSource = `
          class SOMAPCMInputProcessor extends AudioWorkletProcessor {
            constructor() {
              super();
              this.buffers = [];
              this.offset = 0;
              this.queued = 0;
              this.deliveredSinceReport = 0;
              this.port.onmessage = event => {
                if (event.data?.type !== 'append') return;
                let samples = event.data.samples;
                if (!(samples instanceof Float32Array) || samples.length === 0) return;
                const maximum = Math.floor(sampleRate * 12);
                while (this.queued + samples.length > maximum && this.buffers.length > 0) {
                  const removed = this.buffers.shift();
                  this.queued -= removed.samples.length - this.offset;
                  if (removed.itemID) {
                    this.port.postMessage({type: 'rejected', itemID: removed.itemID, reason: 'input_queue_overflow'});
                  }
                  this.offset = 0;
                }
                if (samples.length > maximum) {
                  if (event.data.itemID) {
                    this.port.postMessage({type: 'rejected', itemID: event.data.itemID, reason: 'input_too_long'});
                  }
                  return;
                }
                this.buffers.push({samples, itemID: event.data.itemID || ''});
                this.queued += samples.length;
              };
            }
            process(inputs, outputs) {
              const output = outputs[0][0];
              output.fill(0);
              let written = 0;
              while (written < output.length && this.buffers.length > 0) {
                const entry = this.buffers[0];
                const buffer = entry.samples;
                const count = Math.min(output.length - written, buffer.length - this.offset);
                output.set(buffer.subarray(this.offset, this.offset + count), written);
                written += count;
                this.offset += count;
                this.queued -= count;
                if (this.offset >= buffer.length) {
                  this.buffers.shift();
                  this.offset = 0;
                  if (entry.itemID) {
                    this.port.postMessage({type: 'drained', itemID: entry.itemID});
                  }
                }
              }
              this.deliveredSinceReport += written;
              if (this.deliveredSinceReport >= sampleRate) {
                this.deliveredSinceReport -= sampleRate;
                this.port.postMessage({type: 'progress'});
              }
              return true;
            }
          }
          registerProcessor('soma-pcm-input', SOMAPCMInputProcessor);
        `;
        const processorURL = URL.createObjectURL(new Blob([processorSource], {type: 'application/javascript'}));
        await inputContext.audioWorklet.addModule(processorURL);
        URL.revokeObjectURL(processorURL);
        inputDestination = inputContext.createMediaStreamDestination();
        inputWorklet = new AudioWorkletNode(inputContext, 'soma-pcm-input', {
          channelCount: 1,
          channelCountMode: 'explicit',
          outputChannelCount: [1],
        });
        inputWorklet.connect(inputDestination);
        inputWorklet.port.onmessage = event => {
          if (event.data?.type === 'progress') send('audio_input_progress');
          if (event.data?.type === 'drained') {
            send('opening_audio_drained', {itemID: event.data.itemID});
          }
          if (event.data?.type === 'rejected') {
            send('opening_audio_rejected', {
              itemID: event.data.itemID,
              reason: event.data.reason || 'audio_worklet_rejected',
            });
          }
        };
        peer = new RTCPeerConnection();
        channel = peer.createDataChannel('oai-events');
        channel.onmessage = event => {
          if (typeof event.data === 'string') send('realtime_event', {payload: event.data});
        };
        channel.onclose = () => send('closed');
        channel.onerror = () => send('data_channel_error', {
          message: 'data_channel_failed',
          dataChannelState: channel?.readyState || 'unknown',
          peerState: peer?.connectionState || 'unknown',
        });
        peer.ontrack = async event => {
          try {
          outputContext = new AudioContext();
          await outputContext.resume();
          // Keep realtime playback inside Web Audio whenever the requested
          // sink is available. Crossing WebKit -> Swift -> AVAudioEngine for
          // every PCM block exposes UI-thread scheduling jitter as audible
          // gaps. The worklet below performs presentation DSP on the audio
          // render thread and only exports a best-effort echo reference.
          let nativePlayback = false;
          let playbackRoute = useVoiceEffects ? 'web_audio_voice_effects' : 'system_default';
          if (!useSystemDefault) {
            try {
              if (typeof outputContext.setSinkId !== 'function') {
                nativePlayback = true;
                playbackRoute = 'native_fallback_no_sink_api';
              } else {
                const devices = await navigator.mediaDevices.enumerateDevices();
                const normalizedName = outputDeviceName.trim().toLocaleLowerCase();
                const sink = devices.find(device =>
                  device.kind === 'audiooutput' &&
                  device.label.trim().toLocaleLowerCase() === normalizedName
                );
                if (!sink) {
                  nativePlayback = true;
                  playbackRoute = 'native_fallback_sink_unresolved';
                } else {
                  await outputContext.setSinkId(sink.deviceId);
                  playbackRoute = 'selected_output';
                }
              }
            } catch (_) {
              nativePlayback = true;
              playbackRoute = 'native_fallback_sink_error';
            }
          }
          const outputProcessorSource = `
            class SOMAPlaybackReferenceProcessor extends AudioWorkletProcessor {
              constructor(options) {
                super();
                this.voiceEffects = options.processorOptions?.voiceEffects === true;
                this.pending = new Float32Array(4096);
                this.pendingCount = 0;
                this.pitchBuffer = new Float32Array(8192);
                this.pitchWrite = 0;
                this.pitchSamplesWritten = 0;
                this.pitchPhase = 0;
                this.pitchWindow = 2048;
                this.pitchMinimumDelay = 256;
                const profile = options.processorOptions?.profile || {};
                const bounded = (value, fallback, minimum, maximum) =>
                  Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
                const pitchCents = bounded(profile.pitchCents, -250, -400, 0);
                const echoFeedback = Array.isArray(profile.echoFeedback) ? profile.echoFeedback : [];
                const echoWet = Array.isArray(profile.echoWet) ? profile.echoWet : [];
                this.echoOneFeedback = bounded(echoFeedback[0], 0.14, 0, 0.45);
                this.echoTwoFeedback = bounded(echoFeedback[1], this.echoOneFeedback, 0, 0.45);
                this.echoOneWet = bounded(echoWet[0], 0.14, 0, 0.35);
                this.echoTwoWet = bounded(echoWet[1], this.echoOneWet, 0, 0.35);
                this.reverbWet = bounded(profile.reverbWet, 0.16, 0, 0.35);
                this.pitchRatio = Math.pow(2, pitchCents / 1200);
                this.pitchPhaseStep = (1 - this.pitchRatio) / this.pitchWindow;
                this.lowState = 0;
                this.bassState = 0;
                this.presenceState = 0;
                this.envelope = 0;
                this.highPassAlpha = 1 - Math.exp(-2 * Math.PI * 65 / sampleRate);
                this.bassAlpha = 1 - Math.exp(-2 * Math.PI * 170 / sampleRate);
                this.presenceAlpha = 1 - Math.exp(-2 * Math.PI * 2400 / sampleRate);
                this.compressorAttack = Math.exp(-1 / (sampleRate * 0.006));
                this.compressorRelease = Math.exp(-1 / (sampleRate * 0.075));
                this.echoOne = new Float32Array(Math.max(1, Math.round(sampleRate * 0.028)));
                this.echoTwo = new Float32Array(Math.max(1, Math.round(sampleRate * 0.056)));
                this.echoOneIndex = 0;
                this.echoTwoIndex = 0;
                this.reverb = [0.0297, 0.0371, 0.0411, 0.0437].map(seconds => ({
                  samples: new Float32Array(Math.max(1, Math.round(sampleRate * seconds))),
                  index: 0,
                }));
                this.port.onmessage = event => {
                  if (event.data?.type === 'reset_presentation') this.resetPresentation();
                };
              }
              resetPresentation() {
                this.pending.fill(0);
                this.pendingCount = 0;
                this.pitchBuffer.fill(0);
                this.pitchWrite = 0;
                this.pitchSamplesWritten = 0;
                this.pitchPhase = 0;
                this.lowState = 0;
                this.bassState = 0;
                this.presenceState = 0;
                this.envelope = 0;
                this.echoOne.fill(0);
                this.echoTwo.fill(0);
                this.echoOneIndex = 0;
                this.echoTwoIndex = 0;
                for (const comb of this.reverb) {
                  comb.samples.fill(0);
                  comb.index = 0;
                }
              }
              readPitch(delay) {
                let position = this.pitchWrite - delay;
                while (position < 0) position += this.pitchBuffer.length;
                const lower = Math.floor(position) % this.pitchBuffer.length;
                const upper = (lower + 1) % this.pitchBuffer.length;
                const fraction = position - Math.floor(position);
                return this.pitchBuffer[lower] * (1 - fraction) + this.pitchBuffer[upper] * fraction;
              }
              shiftPitch(sample) {
                this.pitchBuffer[this.pitchWrite] = sample;
                this.pitchWrite = (this.pitchWrite + 1) % this.pitchBuffer.length;
                this.pitchSamplesWritten += 1;
                if (this.pitchSamplesWritten < this.pitchWindow + this.pitchMinimumDelay) return sample;
                this.pitchPhase += this.pitchPhaseStep;
                if (this.pitchPhase >= 1) this.pitchPhase -= 1;
                const secondPhase = (this.pitchPhase + 0.5) % 1;
                const firstWeight = 0.5 - 0.5 * Math.cos(2 * Math.PI * this.pitchPhase);
                const secondWeight = 1 - firstWeight;
                const first = this.readPitch(this.pitchMinimumDelay + this.pitchPhase * this.pitchWindow);
                const second = this.readPitch(this.pitchMinimumDelay + secondPhase * this.pitchWindow);
                return first * firstWeight + second * secondWeight;
              }
              present(sample) {
                let value = this.shiftPitch(sample);

                // Speech-focused tone shaping: remove rumble, add a restrained
                // low shelf and presence, then compress before spatial effects.
                this.lowState += this.highPassAlpha * (value - this.lowState);
                value -= this.lowState;
                this.bassState += this.bassAlpha * (value - this.bassState);
                this.presenceState += this.presenceAlpha * (value - this.presenceState);
                value += 0.32 * this.bassState + 0.10 * (value - this.presenceState);
                const magnitude = Math.abs(value);
                const coefficient = magnitude > this.envelope
                  ? this.compressorAttack
                  : this.compressorRelease;
                this.envelope = coefficient * this.envelope + (1 - coefficient) * magnitude;
                if (this.envelope > 0.28) {
                  value *= Math.pow(0.28 / this.envelope, 0.42);
                }

                const echoOne = this.echoOne[this.echoOneIndex];
                const echoTwo = this.echoTwo[this.echoTwoIndex];
                this.echoOne[this.echoOneIndex] = value + echoOne * this.echoOneFeedback;
                this.echoTwo[this.echoTwoIndex] = value + echoTwo * this.echoTwoFeedback;
                this.echoOneIndex = (this.echoOneIndex + 1) % this.echoOne.length;
                this.echoTwoIndex = (this.echoTwoIndex + 1) % this.echoTwo.length;

                let reverbSum = 0;
                for (const comb of this.reverb) {
                  const delayed = comb.samples[comb.index];
                  comb.samples[comb.index] = value + delayed * 0.78;
                  comb.index = (comb.index + 1) % comb.samples.length;
                  reverbSum += delayed;
                }
                value += echoOne * this.echoOneWet
                  + echoTwo * this.echoTwoWet
                  + reverbSum * (this.reverbWet / this.reverb.length);
                return Math.tanh(value * 1.05) / Math.tanh(1.05);
              }
              process(inputs, outputs) {
                const inputChannels = inputs[0];
                const outputChannels = outputs[0];
                for (const output of outputChannels) output.fill(0);
                if (!inputChannels || inputChannels.length === 0) return true;
                const frameCount = inputChannels[0].length;
                for (let frame = 0; frame < frameCount; frame++) {
                  let sum = 0;
                  for (const channel of inputChannels) sum += channel[frame] || 0;
                  const mono = sum / inputChannels.length;
                  const presented = this.voiceEffects ? this.present(mono) : mono;
                  for (const output of outputChannels) output[frame] = presented;
                  this.pending[this.pendingCount++] = presented;
                  if (this.pendingCount === this.pending.length) {
                    const block = this.pending;
                    this.pending = new Float32Array(4096);
                    this.pendingCount = 0;
                    this.port.postMessage({type: 'reference', samples: block}, [block.buffer]);
                  }
                }
                return true;
              }
            }
            registerProcessor('soma-playback-reference', SOMAPlaybackReferenceProcessor);
          `;
          const outputProcessorURL = URL.createObjectURL(
            new Blob([outputProcessorSource], {type: 'application/javascript'})
          );
          await outputContext.audioWorklet.addModule(outputProcessorURL);
          URL.revokeObjectURL(outputProcessorURL);
          const outputSource = outputContext.createMediaStreamSource(event.streams[0]);
          outputWorklet = new AudioWorkletNode(outputContext, 'soma-playback-reference', {
            channelCount: 1,
            channelCountMode: 'explicit',
            outputChannelCount: [1],
            processorOptions: {
              // If browser sink routing is unavailable, Swift's native path
              // remains the fallback and owns the DSP instead.
              voiceEffects: useVoiceEffects && !nativePlayback,
              profile: voiceEffectProfile,
            },
          });
          outputSource.connect(outputWorklet);
          outputGate = outputContext.createGain();
          outputGate.gain.value = visualOutputGateClosed ? 0 : 1;
          outputWorklet.connect(outputGate);
          if (nativePlayback) {
            const silentOutput = outputContext.createGain();
            silentOutput.gain.value = 0;
            outputGate.connect(silentOutput);
            silentOutput.connect(outputContext.destination);
          } else {
            outputGate.connect(outputContext.destination);
          }
          outputWorklet.port.onmessage = message => {
            if (message.data?.type !== 'reference') return;
            const samples = message.data.samples;
            if (!(samples instanceof Float32Array) || samples.length === 0) return;
            let energy = 0;
            for (const sample of samples) energy += sample * sample;
            const rms = Math.sqrt(energy / samples.length);
            const wasSpeaking = outputSpeaking;
            if (rms >= 0.0005) {
              outputAboveCount += 1;
              outputBelowCount = 0;
            } else {
              outputAboveCount = 0;
              outputBelowCount += 1;
            }
            const startsOutput = !outputSpeaking && outputAboveCount >= 1;
            const endsOutput = outputSpeaking && outputBelowCount >= 20;
            if (startsOutput) {
              outputSpeaking = true;
            } else if (endsOutput) {
              outputSpeaking = false;
            }
            if (rms < 0.0005 && !wasSpeaking && !outputSpeaking) return;
            const bytes = new Uint8Array(samples.length * 2);
            for (let index = 0; index < samples.length; index++) {
              const scaled = Math.max(-32768, Math.min(32767, Math.round(samples[index] * 32768)));
              bytes[index * 2] = scaled & 255;
              bytes[index * 2 + 1] = (scaled >> 8) & 255;
            }
            send('output_reference', {
              data: btoa(String.fromCharCode(...bytes)),
              sampleRate: outputContext.sampleRate,
              samplesPerChannel: samples.length,
              numChannels: 1,
              startsOutput,
              endsOutput,
              nativePlayback,
            });
          };
          send('output_playback_ready', {
            mode: nativePlayback ? 'native_fallback' : 'browser_realtime',
            route: playbackRoute,
            effectProfile: useVoiceEffects && !nativePlayback ? 'space_marine' : 'none',
          });
          } catch (error) {
            send('error', {message: 'output_audio_pipeline_failed: ' + String(error)});
          }
        };
        peer.onconnectionstatechange = () => {
          if (peer.connectionState === 'connected') send('connected');
          if (peer.connectionState === 'failed') send('error', {message: 'peer_connection_failed'});
          if (peer.connectionState === 'closed') send('closed');
        };
        const inputTrack = inputDestination.stream.getAudioTracks()[0];
        peer.addTrack(inputTrack, inputDestination.stream);
        send('audio_input_ready', {state: inputContext.state, trackState: inputTrack.readyState});
        const offer = await peer.createOffer();
        await peer.setLocalDescription(offer);
        send('offer', {sdp: offer.sdp});
      } catch (error) {
        send('error', {message: String(error)});
      }
    }
    async function acceptAnswer(sdp) {
      try {
        await peer.setRemoteDescription({type: 'answer', sdp});
      } catch (error) {
        send('error', {message: String(error)});
      }
    }
    function appendPCM16(base64, sampleRate, sampleCount, itemID = '') {
      if (!inputContext || !inputWorklet || sampleCount <= 0) return false;
      const binary = atob(base64);
      if (binary.length !== sampleCount * 2) throw new Error('pcm16_size_mismatch');
      const source = new Float32Array(sampleCount);
      for (let index = 0; index < sampleCount; index++) {
        const low = binary.charCodeAt(index * 2);
        const high = binary.charCodeAt(index * 2 + 1);
        let value = low | (high << 8);
        if (value >= 32768) value -= 65536;
        source[index] = value / 32768;
      }
      let destination = source;
      if (sampleRate !== inputContext.sampleRate) {
        const outputCount = Math.max(1, Math.round(source.length * inputContext.sampleRate / sampleRate));
        destination = new Float32Array(outputCount);
        const scale = (source.length - 1) / Math.max(1, outputCount - 1);
        for (let index = 0; index < outputCount; index++) {
          const position = index * scale;
          const lower = Math.floor(position);
          const upper = Math.min(source.length - 1, lower + 1);
          const fraction = position - lower;
          destination[index] = source[lower] * (1 - fraction) + source[upper] * fraction;
        }
      }
      inputWorklet.port.postMessage(
        {type: 'append', samples: destination, itemID},
        [destination.buffer]
      );
      return true;
    }
    function sendRealtimeControl(payload) {
      if (!channel || channel.readyState !== 'open' || !payload || typeof payload.type !== 'string') {
        return false;
      }
      channel.send(JSON.stringify(payload));
      return true;
    }
    function setVisualOutputGate(closed, resetPresentation = false) {
      visualOutputGateClosed = closed === true;
      if (resetPresentation && outputWorklet) {
        outputWorklet.port.postMessage({type: 'reset_presentation'});
        outputSpeaking = false;
        outputAboveCount = 0;
        outputBelowCount = 0;
      }
      if (outputGate && outputContext) {
        outputGate.gain.cancelScheduledValues(outputContext.currentTime);
        outputGate.gain.setValueAtTime(visualOutputGateClosed ? 0 : 1, outputContext.currentTime);
      }
      return true;
    }
    function stopWebRTC() {
      if (channel) channel.close();
      if (peer) peer.close();
      if (stream) for (const track of stream.getTracks()) track.stop();
      if (inputWorklet) inputWorklet.disconnect();
      if (inputContext) inputContext.close().catch(() => {});
      if (outputContext) outputContext.close().catch(() => {});
    }
    </script></body></html>
    """
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let emitter = JSONLineEmitter()
    private let workingDirectory: String
    private let voice: String
    private let voiceMode: SOMARealtimeVoiceMode
    private let outputDeviceUID: String?
    private var runtime: LiveVoiceRuntime!

    init(
        workingDirectory: String,
        voice: String,
        voiceMode: SOMARealtimeVoiceMode,
        outputDeviceUID: String?
    ) {
        self.workingDirectory = workingDirectory
        self.voice = voice
        self.voiceMode = voiceMode
        self.outputDeviceUID = outputDeviceUID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = LiveVoiceRuntime(
            emitter: emitter,
            workingDirectory: workingDirectory,
            voice: voice,
            voiceMode: voiceMode,
            preferredOutputDeviceUID: outputDeviceUID
        )
        runtime.prepare()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let command = try? JSONDecoder().decode(Command.self, from: data) else {
                    self?.emitter.emit("failed", fields: ["reason": "invalid_control_command"])
                    continue
                }
                DispatchQueue.main.async { self?.runtime.receive(command) }
            }
            DispatchQueue.main.async {
                self?.runtime.receive(Command(
                    type: .stop,
                    initialContext: nil,
                    preferredLanguageTag: nil,
                    languageStartInstruction: nil,
                    proactiveOpeningText: nil,
                    interactionAuthority: nil,
                    personContextReference: nil,
                    sessionCapability: nil,
                    embodimentSocketPath: nil,
                    appServerURL: nil,
                    cameraContextAutoInjected: nil,
                    codexSandbox: nil,
                    codexAdminOnly: nil,
                    hermesAgentDelegationEnabled: nil,
                    data: nil,
                    sampleRate: nil,
                    samplesPerChannel: nil,
                    itemID: nil,
                    taskID: nil,
                    tool: nil
                ))
            }
        }
        emitter.emit("ready", fields: ["transport": "app_server_webrtc"])
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
var workingDirectory = FileManager.default.currentDirectoryPath
var voice = SOMARealtimeVoice.maple.rawValue
var voiceMode = SOMARealtimeVoiceMode.natural
var outputDeviceUID: String?
var verifyAudioGraph = false
var argumentIndex = 0
while argumentIndex < arguments.count {
    switch arguments[argumentIndex] {
    case "--cwd":
        argumentIndex += 1
        guard argumentIndex < arguments.count, arguments[argumentIndex].hasPrefix("/") else {
            fputs("soma-live-voice: --cwd requires an absolute path\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
        workingDirectory = arguments[argumentIndex]
    case "--voice":
        argumentIndex += 1
        guard argumentIndex < arguments.count,
              let selectedVoice = SOMARealtimeVoice(rawValue: arguments[argumentIndex]) else {
            fputs("soma-live-voice: --voice is not supported by the installed app-server contract\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
        voice = selectedVoice.rawValue
    case "--voice-mode":
        argumentIndex += 1
        guard argumentIndex < arguments.count,
              let selectedMode = SOMARealtimeVoiceMode(rawValue: arguments[argumentIndex]) else {
            fputs("soma-live-voice: --voice-mode is not supported\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
        voiceMode = selectedMode
    case "--output-device-uid":
        argumentIndex += 1
        guard argumentIndex < arguments.count,
              let normalized = SOMAControlSettings.normalizedDeviceUID(arguments[argumentIndex]) else {
            fputs("soma-live-voice: --output-device-uid requires a device UID\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
        outputDeviceUID = normalized
    case "--verify-audio-graph":
        verifyAudioGraph = true
    default:
        fputs("usage: soma-live-voice [--cwd /absolute/project] [--voice name] [--voice-mode natural|space_marine] [--output-device-uid uid] [--verify-audio-graph]\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    argumentIndex += 1
}

if verifyAudioGraph {
    do {
        try MainActor.assumeIsolated {
            let verificationHandler: (@Sendable (SelectedAudioOutput.RenderedPCM) -> Void)?
            if voiceMode.requiresProcessedPlayback {
                verificationHandler = { _ in }
            } else {
                verificationHandler = nil
            }
            let output = try SelectedAudioOutput(
                preferredUID: outputDeviceUID,
                voiceMode: voiceMode,
                renderedPCMHandler: verificationHandler
            )
            let sampleCount = 960
            var verificationPCM = Data(count: sampleCount * 2)
            verificationPCM.withUnsafeMutableBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for sampleIndex in 0..<sampleCount {
                    let phase = Double(sampleIndex) * 2 * Double.pi * 220 / 48_000
                    let integer = Int16((sin(phase) * 2_048).rounded())
                    let bits = UInt16(bitPattern: integer)
                    bytes[sampleIndex * 2] = UInt8(bits & 0x00ff)
                    bytes[sampleIndex * 2 + 1] = UInt8((bits >> 8) & 0x00ff)
                }
            }
            try output.enqueuePCM16(
                verificationPCM,
                sampleRate: 48_000,
                channels: 1,
                samplesPerChannel: sampleCount
            )
            output.finishSpeech()
            Thread.sleep(forTimeInterval: 0.08)
            output.flush()
            output.stop()
            print("audio_graph_ok mode=\(voiceMode.rawValue) route=\(output.resolution)")
        }
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-live-voice: audio graph verification failed: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let delegate = AppDelegate(
    workingDirectory: workingDirectory,
    voice: voice,
    voiceMode: voiceMode,
    outputDeviceUID: outputDeviceUID
)
application.delegate = delegate
application.run()
