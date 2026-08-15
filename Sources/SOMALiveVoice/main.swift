import AppKit
import Foundation
import SOMACore
import WebKit

private struct Command: Decodable {
    enum Kind: String, Decodable {
        case start
        case appendAudio = "append_audio"
        case appendText = "append_text"
        case stop
    }

    let type: Kind
    let initialContext: String?
    let preferredLanguageTag: String?
    let languageStartInstruction: String?
    let text: String?
    let role: String?
    let data: String?
    let sampleRate: Int?
    let samplesPerChannel: Int?
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
    private var buffer = Data()
    private var nextRequestID = 1
    private var handlers: [Int: ResponseHandler] = [:]
    private let notificationHandler: NotificationHandler

    init(notificationHandler: @escaping NotificationHandler) {
        self.notificationHandler = notificationHandler
    }

    func start(codexURL: URL, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            self.process.executableURL = codexURL
            self.process.arguments = ["app-server", "--stdio", "--enable", "realtime_conversation"]
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
                self.request(
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
            } catch {
                completion(.failure(error))
            }
        }
    }

    func request(
        method: String,
        params: [String: Any],
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
        }
    }

    func stop() {
        queue.sync {
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

    private func notify(method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
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

@MainActor
private final class LiveVoiceRuntime: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private let emitter: JSONLineEmitter
    private let workingDirectory: String
    private let voice: String
    private var connection: AppServerConnection!
    private var webView: WKWebView!
    private var window: NSWindow!
    private var threadID: String?
    private var initialContext = ""
    private var preferredLanguageTag: String?
    private var languageStartInstruction: String?
    private var pendingCommands: [Command] = []
    private var webViewReady = false
    private var stopping = false
    private var startRequestAccepted = false
    private var appServerStarted = false
    private var webRTCConnected = false
    private var realtimeSessionInitialized = false
    private var activeEmitted = false
    private var observedRealtimeEventTypes: Set<String> = []

    init(emitter: JSONLineEmitter, workingDirectory: String, voice: String) {
        self.emitter = emitter
        self.workingDirectory = workingDirectory
        self.voice = voice
        super.init()
        connection = AppServerConnection { [weak self] method, params in
            DispatchQueue.main.async {
                self?.handleNotification(method: method, params: params.value)
            }
        }
    }

    func prepare() {
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
        guard webViewReady else {
            pendingCommands.append(command)
            return
        }
        switch command.type {
        case .start:
            guard threadID == nil else { return }
            initialContext = String((command.initialContext ?? "").prefix(24_000))
            preferredLanguageTag = (command.preferredLanguageTag ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            languageStartInstruction = (command.languageStartInstruction ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            startAppServer()
        case .appendText:
            guard let threadID,
                  let text = command.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            let role = ["user", "developer", "assistant"].contains(command.role ?? "")
                ? command.role!
                : "developer"
            connection.request(
                method: "thread/realtime/appendText",
                params: ["threadId": threadID, "text": String(text.prefix(8_192)), "role": role]
            ) { [weak self] response in
                guard response.value["error"] == nil else {
                    self?.emitter.emit("context_rejected", fields: [
                        "reason": AppServerConnection.responseMessage(response.value),
                    ])
                    return
                }
                self?.emitter.emit("context_appended", fields: ["role": role])
            }
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
        case .stop:
            stop(reason: "control_stop")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewReady = true
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands { receive(command) }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }
        switch event {
        case "offer":
            guard let sdp = body["sdp"] as? String else {
                fail(LiveVoiceError.webRTC("offer_missing_sdp"))
                return
            }
            startRealtime(offerSDP: sdp)
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
        case "output_playback_ready":
            emitter.emit("output_playback_ready")
        case "output_speech_started":
            emitter.emit("output_speech_started")
        case "output_speech_ended":
            emitter.emit("output_speech_ended")
        case "realtime_event":
            handleRealtimeDataChannel(body["payload"] as? String ?? "")
        case "closed":
            stop(reason: "webrtc_closed")
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
        emitter.emit("starting", fields: ["transport": "app_server_webrtc"])
        connection.start(codexURL: codexURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
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
        connection.request(
            method: "thread/start",
            params: [
                "cwd": workingDirectory,
                "threadSource": "realtime_voice",
                "ephemeral": true,
                "approvalPolicy": "never",
                "sandbox": "danger-full-access",
            ]
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
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
                self.webView.evaluateJavaScript("void startWebRTC()") { _, error in
                    if let error { self.fail(error) }
                }
            }
        }
    }

    private func startRealtime(offerSDP: String) {
        guard let threadID else {
            fail(LiveVoiceError.webRTC("thread_not_ready"))
            return
        }
        let baseInstruction = "You are SOMA's L2 conversational reasoning layer. Respond naturally by voice. Treat supplied L0 and L1 context as evidence, not as user speech. The active session has the soma_embodiment MCP server: use its person-context tools when supplied context includes a person-context reference; only write a preference, rapport value, or fact after the person explicitly states or confirms it. Keep replies concise unless the user asks for depth. Delegate tool or work requests through Codex when useful. Never claim to see an image unless it is attached or returned by a tool."
        let instruction = [baseInstruction, languageInstruction()]
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
        ]
        if !initialContext.isEmpty {
            params["initialItems"] = [["role": "developer", "text": initialContext]]
        }
        connection.request(method: "thread/realtime/start", params: params) { [weak self] response in
            guard response.value["error"] == nil else {
                DispatchQueue.main.async {
                    self?.fail(LiveVoiceError.appServerResponse(
                        AppServerConnection.responseMessage(response.value)
                    ))
                }
                return
            }
            DispatchQueue.main.async {
                self?.startRequestAccepted = true
                self?.activateIfReady()
            }
        }
    }

    private func languageInstruction() -> String? {
        if let languageStartInstruction, !languageStartInstruction.isEmpty {
            return """
            The following L1-authored language directive is binding for every spoken token, including the first greeting or question. Do not default to English and do not switch languages unless the participant clearly asks to do so.
            L1 language directive:
            \(String(languageStartInstruction.prefix(1_024)))
            """
        }
        guard let rawTag = preferredLanguageTag,
              let tag = PersonContextFormat.normalizedLanguageTag(rawTag) else {
            return nil
        }
        return "The participant's explicit response-language preference is \(tag). Respond in that language unless they clearly switch language or ask otherwise."
    }

    private func handleNotification(method: String, params: [String: Any]) {
        guard params["threadId"] as? String == threadID else { return }
        switch method {
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
        case "thread/realtime/transcript/done":
            guard params["role"] as? String == "user",
                  let text = params["text"] as? String,
                  !text.isEmpty else { return }
            emitter.emit("input_transcript_ready", fields: ["characters": min(text.count, 65_535)])
        case "thread/realtime/closed":
            stop(reason: params["reason"] as? String ?? "realtime_closed")
        default:
            break
        }
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
        if type == "session.started" || type == "session.updated" {
            realtimeSessionInitialized = true
            activateIfReady()
            return
        }
        if type.contains("speech_started") {
            emitter.emit("input_speech_started")
            return
        }
        if type.hasPrefix("input_transcript.") {
            let text = (object["transcript"] as? String) ?? (object["text"] as? String) ?? ""
            if !text.isEmpty {
                emitter.emit("input_transcript_ready", fields: ["characters": min(text.count, 65_535)])
            }
            return
        }
        if type == "turn.created" || type.contains("response.created") {
            emitter.emit("response_preparing")
            return
        }
        if type == "turn.completed" || type == "turn.finished" || type == "turn.done" ||
            type.contains("response.completed") || type.contains("response.done") {
            emitter.emit("response_completed")
        }
    }

    private func activateIfReady() {
        guard !activeEmitted,
              startRequestAccepted,
              appServerStarted,
              webRTCConnected,
              realtimeSessionInitialized else { return }
        activeEmitted = true
        emitter.emit("active", fields: ["thread_id": threadID ?? ""])
    }

    private func fail(_ error: Error) {
        emitter.emit("failed", fields: ["reason": String(error.localizedDescription.prefix(256))])
        stop(reason: "failed", emitEnded: false)
    }

    private func stop(reason: String, emitEnded: Bool = true) {
        guard !stopping else { return }
        stopping = true
        if let threadID {
            connection.request(method: "thread/realtime/stop", params: ["threadId": threadID]) { _ in }
        }
        webView.evaluateJavaScript("void stopWebRTC()")
        connection.stop()
        if emitEnded { emitter.emit("ended", fields: ["reason": String(reason.prefix(128))]) }
        NSApplication.shared.terminate(nil)
    }

    private static func codexURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SOMA_CODEX_BINARY"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return nil
        }
        let url = appURL.appendingPathComponent("Contents/Resources/codex")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static let webRTCHTML = """
    <!doctype html><html><body><script>
    let peer = null;
    let stream = null;
    let channel = null;
    let audio = null;
    let inputContext = null;
    let inputDestination = null;
    let inputWorklet = null;
    let outputContext = null;
    let outputAnalyser = null;
    let outputTimer = null;
    let outputSpeaking = false;
    let outputAboveCount = 0;
    let outputBelowCount = 0;
    function send(event, extra = {}) {
      window.webkit.messageHandlers.soma.postMessage(Object.assign({event}, extra));
    }
    async function startWebRTC() {
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
                const maximum = Math.floor(sampleRate * 3);
                while (this.queued + samples.length > maximum && this.buffers.length > 0) {
                  const removed = this.buffers.shift();
                  this.queued -= removed.length - this.offset;
                  this.offset = 0;
                }
                if (samples.length > maximum) samples = samples.slice(samples.length - maximum);
                this.buffers.push(samples);
                this.queued += samples.length;
              };
            }
            process(inputs, outputs) {
              const output = outputs[0][0];
              output.fill(0);
              let written = 0;
              while (written < output.length && this.buffers.length > 0) {
                const buffer = this.buffers[0];
                const count = Math.min(output.length - written, buffer.length - this.offset);
                output.set(buffer.subarray(this.offset, this.offset + count), written);
                written += count;
                this.offset += count;
                this.queued -= count;
                if (this.offset >= buffer.length) {
                  this.buffers.shift();
                  this.offset = 0;
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
        };
        peer = new RTCPeerConnection();
        audio = document.createElement('audio');
        audio.autoplay = true;
        audio.hidden = true;
        document.body.appendChild(audio);
        channel = peer.createDataChannel('oai-events');
        channel.onmessage = event => {
          if (typeof event.data === 'string') send('realtime_event', {payload: event.data});
        };
        channel.onclose = () => send('closed');
        channel.onerror = () => send('error', {message: 'data_channel_failed'});
        peer.ontrack = event => {
          audio.srcObject = event.streams[0];
          audio.play()
            .then(() => send('output_playback_ready'))
            .catch(error => send('error', {message: 'audio_playback_failed: ' + String(error)}));
          outputContext = new AudioContext();
          outputContext.resume().catch(() => {});
          const outputSource = outputContext.createMediaStreamSource(event.streams[0]);
          outputAnalyser = outputContext.createAnalyser();
          outputAnalyser.fftSize = 256;
          const silentGain = outputContext.createGain();
          silentGain.gain.value = 0;
          outputSource.connect(outputAnalyser);
          outputAnalyser.connect(silentGain);
          silentGain.connect(outputContext.destination);
          const levels = new Float32Array(outputAnalyser.fftSize);
          outputTimer = setInterval(() => {
            outputAnalyser.getFloatTimeDomainData(levels);
            let energy = 0;
            for (const value of levels) energy += value * value;
            const rms = Math.sqrt(energy / levels.length);
            if (rms >= 0.004) {
              outputAboveCount += 1;
              outputBelowCount = 0;
            } else {
              outputAboveCount = 0;
              outputBelowCount += 1;
            }
            if (!outputSpeaking && outputAboveCount >= 2) {
              outputSpeaking = true;
              send('output_speech_started');
            } else if (outputSpeaking && outputBelowCount >= 6) {
              outputSpeaking = false;
              send('output_speech_ended');
            }
          }, 50);
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
    function appendPCM16(base64, sampleRate, sampleCount) {
      if (!inputContext || !inputWorklet || sampleCount <= 0) return;
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
      inputWorklet.port.postMessage({type: 'append', samples: destination}, [destination.buffer]);
    }
    function stopWebRTC() {
      if (outputTimer) clearInterval(outputTimer);
      if (channel) channel.close();
      if (peer) peer.close();
      if (stream) for (const track of stream.getTracks()) track.stop();
      if (audio) { audio.pause(); audio.srcObject = null; }
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
    private var runtime: LiveVoiceRuntime!

    init(workingDirectory: String, voice: String) {
        self.workingDirectory = workingDirectory
        self.voice = voice
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = LiveVoiceRuntime(emitter: emitter, workingDirectory: workingDirectory, voice: voice)
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
                    text: nil,
                    role: nil,
                    data: nil,
                    sampleRate: nil,
                    samplesPerChannel: nil
                ))
            }
        }
        emitter.emit("ready", fields: ["transport": "app_server_webrtc"])
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
var workingDirectory = FileManager.default.currentDirectoryPath
var voice = SOMARealtimeVoice.maple.rawValue
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
    default:
        fputs("usage: soma-live-voice [--cwd /absolute/project] [--voice name]\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    argumentIndex += 1
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let delegate = AppDelegate(workingDirectory: workingDirectory, voice: voice)
application.delegate = delegate
application.run()
