import Foundation
import SOMACore

enum AppServerLiveVoiceEvent: Sendable {
    case launchRequested(authorization: String, personEntityID: UUID?)
    case active(threadID: String?, personEntityID: UUID?)
    case inputTransportStarted
    case outputPlaybackReady
    case proactiveOpeningTriggered
    case hearingUser
    case contextAppended
    case contextRejected(reason: String)
    case visualContextAttached
    case visualContextRejected(reason: String)
    case embodimentMCPReady
    case embodimentMCPUnavailable(reason: String)
    case inputAccepted(characters: Int)
    case transcriptFinalized(threadID: String?, role: ConversationParticipantRole, text: String)
    case preparingResponse
    case responding
    case responseCompleted
    case ended(threadID: String?, personEntityID: UUID?, reason: String)
    case failed(threadID: String?, personEntityID: UUID?, reason: String)
}

private struct LiveVoiceHelperEvent: Decodable, Sendable {
    let event: String
    let threadID: String?
    let reason: String?
    let characters: Int?
    let role: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case event
        case threadID = "thread_id"
        case reason
        case characters
        case role
        case text
    }
}

private struct BufferedLiveAudio: Sendable {
    let data: String
    let sampleRate: Int
    let samplesPerChannel: Int
    let durationNS: UInt64
}

final class AppServerLiveVoiceLauncher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.live-voice.app-server", qos: .userInitiated)
    private let projectDirectory: String
    private let voice: SOMARealtimeVoice
    private let currentCameraImageDataURI: (@Sendable () -> String?)?
    private let onEvent: @Sendable (AppServerLiveVoiceEvent) -> Void
    private var gate = LiveVoiceLaunchGate()
    private var inactivityGate = LiveVoiceSessionInactivityGate()
    private var inactivityTimer: DispatchWorkItem?
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var preRoll: [BufferedLiveAudio] = []
    private var preRollDurationNS: UInt64 = 0
    private var audioAccumulator: [Float] = []
    private var audioAccumulatorSampleRate = 0
    private var pendingContext: (text: String, role: String)?
    private var inputTransportReported = false
    private var active = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var activePersonEntityID: UUID?
    private var activeThreadID: String?
    private var lastVisualContextNS: UInt64 = 0

    init(
        projectDirectory: String = "/Users/seungyeop/workspace/Research/SOMA",
        voice: SOMARealtimeVoice = .maple,
        currentCameraImageDataURI: (@Sendable () -> String?)? = nil,
        onEvent: @escaping @Sendable (AppServerLiveVoiceEvent) -> Void
    ) {
        self.projectDirectory = projectDirectory
        self.voice = voice
        self.currentCameraImageDataURI = currentCameraImageDataURI
        self.onEvent = onEvent
    }

    func startIfNeeded(
        authorization: String,
        context: CodexInteractionContext?,
        personEntityID: UUID? = nil,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            if active {
                recordUserActivity(at: monotonicNS)
                return
            }
            guard gate.beginLaunch(at: monotonicNS) else { return }
            launch(
                authorization: String(authorization.prefix(64)),
                initialContext: context.map(Self.contextText) ?? "",
                preferredLanguageTag: context?.preferredLanguageTag,
                languageStartInstruction: context?.languageStartInstruction,
                proactiveOpeningTrigger: nil,
                personEntityID: personEntityID,
                interactionAuthority: context?.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// Starts the same account-backed Live session for an L1-authorized social
    /// opening. The directive is short-lived session context, not a stored
    /// transcript or a substitute for the normal conversation gate.
    func startProactiveOpening(
        text: String,
        context: CodexInteractionContext?,
        personEntityID: UUID,
        at monotonicNS: UInt64
    ) {
        let normalized = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !normalized.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard gate.beginLaunch(at: monotonicNS) else { return }
            let base = context.map(Self.contextText) ?? ""
            let directive = "This is a closed-purpose L1-initiated interaction. Treat the supplied objective and completion condition as private conversational orientation, never as text to recite or a checklist to expose. Start with exactly one brief question that serves that objective, then listen. After each reply, lead only one natural conversational step at a time: follow up when it genuinely clarifies the same purpose, shift into ordinary reciprocal conversation when the person reciprocates, and stop pursuing the purpose after it is answered or declined. Do not dump multiple questions, narrate your plan, replace the opening with a generic greeting or offer of help, or invent another motive. If the purpose cannot be preserved, remain silent. Suggested first question: \(normalized)"
            launch(
                authorization: "l1_social_opening",
                initialContext: String([base, directive].filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(24_000)),
                preferredLanguageTag: context?.preferredLanguageTag,
                languageStartInstruction: context?.languageStartInstruction,
                proactiveOpeningTrigger: "Controller event, not user speech: L1 has authorized the proactive opening described in the developer context. Speak exactly one brief opening question now, then listen.",
                personEntityID: personEntityID,
                interactionAuthority: context?.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    func appendContext(_ text: String, role: String = "developer") {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let bounded = String(normalized.prefix(8_192))
            guard active else {
                pendingContext = (bounded, role)
                return
            }
            send([
                "type": "append_text",
                "text": bounded,
                "role": role,
            ])
        }
    }

    /// Delivers a late L1-derived session directive only to an already-open
    /// conversation. Startup directives travel in the initial session request.
    func appendActiveContext(_ text: String, role: String = "developer") {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.active else { return }
            send([
                "type": "append_text",
                "text": String(normalized.prefix(8_192)),
                "role": role,
            ])
        }
    }

    func ingestAudio(samples: [Float], sampleRateHz: Double, durationNS _: UInt64) {
        guard !samples.isEmpty,
              sampleRateHz.isFinite,
              sampleRateHz >= 8_000,
              sampleRateHz <= 96_000 else { return }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            let sampleRate = Int(sampleRateHz.rounded())
            if audioAccumulatorSampleRate != 0, audioAccumulatorSampleRate != sampleRate {
                flushAudioAccumulator()
            }
            audioAccumulatorSampleRate = sampleRate
            audioAccumulator.append(contentsOf: samples)
            let targetSamples = max(1, sampleRate * 60 / 1_000)
            while audioAccumulator.count >= targetSamples {
                let packet = Array(audioAccumulator.prefix(targetSamples))
                audioAccumulator.removeFirst(targetSamples)
                routeAudioPacket(packet, sampleRate: sampleRate)
            }
        }
    }

    private func flushAudioAccumulator() {
        guard audioAccumulatorSampleRate > 0, !audioAccumulator.isEmpty else { return }
        let packet = audioAccumulator
        audioAccumulator.removeAll(keepingCapacity: true)
        routeAudioPacket(packet, sampleRate: audioAccumulatorSampleRate)
    }

    private func routeAudioPacket(_ samples: [Float], sampleRate: Int) {
        let durationNS = UInt64(
            (Double(samples.count) / Double(sampleRate) * 1_000_000_000).rounded()
        )
        let chunk = BufferedLiveAudio(
            data: Self.pcm16Data(samples).base64EncodedString(),
            sampleRate: sampleRate,
            samplesPerChannel: samples.count,
            durationNS: durationNS
        )
        if active {
            send(chunk)
        } else {
            preRoll.append(chunk)
            preRollDurationNS &+= durationNS
            while preRollDurationNS > 1_000_000_000, preRoll.count > 1 {
                preRollDurationNS -= preRoll.removeFirst().durationNS
            }
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            let lifecycle: (threadID: String?, personEntityID: UUID?)? =
                active || activeThreadID != nil || activePersonEntityID != nil
                ? (activeThreadID, activePersonEntityID)
                : nil
            stopped = true
            generation &+= 1
            _ = send(["type": "stop"], reportFailure: false)
            input = nil
            if let process, process.isRunning { process.terminate() }
            self.process = nil
            active = false
            activeThreadID = nil
            activePersonEntityID = nil
            preRoll.removeAll(keepingCapacity: false)
            preRollDurationNS = 0
            audioAccumulator.removeAll(keepingCapacity: false)
            audioAccumulatorSampleRate = 0
            pendingContext = nil
            inactivityTimer?.cancel()
            inactivityTimer = nil
            inactivityGate.close()
            if let lifecycle {
                onEvent(.failed(
                    threadID: lifecycle.threadID,
                    personEntityID: lifecycle.personEntityID,
                    reason: "service_shutdown"
                ))
            }
        }
    }

    private func launch(
        authorization: String,
        initialContext: String,
        preferredLanguageTag: String?,
        languageStartInstruction: String?,
        proactiveOpeningTrigger: String?,
        personEntityID: UUID?,
        interactionAuthority: SOMAInteractionAuthority?,
        at monotonicNS: UInt64
    ) {
        inputTransportReported = false
        guard let helperURL = helperURL() else {
            gate.fail(at: monotonicNS)
            onEvent(.failed(
                threadID: nil,
                personEntityID: personEntityID,
                reason: "live_voice_helper_not_found"
            ))
            return
        }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--cwd", projectDirectory, "--voice", voice.rawValue]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            queue.async { self.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            queue.async {
                guard self.process === process, !self.stopped else { return }
                self.process = nil
                self.input = nil
                self.active = false
                self.gate.fail(at: DispatchTime.now().uptimeNanoseconds)
                let threadID = self.activeThreadID
                let personEntityID = self.activePersonEntityID
                self.activeThreadID = nil
                self.activePersonEntityID = nil
                self.onEvent(.failed(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: "live_voice_helper_exited_\(process.terminationStatus)"
                ))
            }
        }
        do {
            try process.run()
        } catch {
            gate.fail(at: monotonicNS)
            onEvent(.failed(
                threadID: nil,
                personEntityID: personEntityID,
                reason: String(error.localizedDescription.prefix(192))
            ))
            return
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        activePersonEntityID = personEntityID
        generation &+= 1
        let launchGeneration = generation
        guard send([
            "type": "start",
            "initialContext": String(initialContext.prefix(24_000)),
            "preferredLanguageTag": preferredLanguageTag ?? "",
            "languageStartInstruction": languageStartInstruction ?? "",
            "proactiveOpeningTrigger": proactiveOpeningTrigger ?? "",
            "interactionAuthority": interactionAuthority?.rawValue ?? "",
            "codexSandbox": somaEnvString("SOMA_L2_CODEX_SANDBOX", default: "danger-full-access"),
            "codexAdminOnly": somaEnvBool("SOMA_L2_CODEX_ADMIN_ONLY", default: false),
        ], reportFailure: false) else {
            failCurrent(reason: "live_voice_start_transport_failed")
            return
        }
        onEvent(.launchRequested(authorization: authorization, personEntityID: personEntityID))
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self,
                  generation == launchGeneration,
                  gate.phase == .starting else { return }
            failCurrent(reason: "live_voice_start_timeout")
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(LiveVoiceHelperEvent.self, from: line) else {
                continue
            }
            switch event.event {
            case "active":
                guard !active else { continue }
                active = true
                activeThreadID = event.threadID
                gate.observeActive()
                armInactivityTimeout(at: DispatchTime.now().uptimeNanoseconds)
                let buffered = preRoll
                preRoll.removeAll(keepingCapacity: true)
                preRollDurationNS = 0
                for chunk in buffered { send(chunk) }
                if let pendingContext {
                    self.pendingContext = nil
                    send([
                        "type": "append_text",
                        "text": pendingContext.text,
                        "role": pendingContext.role,
                    ])
                }
                enqueueCurrentCameraImageIfEnabled(force: true)
                onEvent(.active(threadID: event.threadID, personEntityID: activePersonEntityID))
            case "audio_input_progress":
                guard !inputTransportReported else { continue }
                inputTransportReported = true
                onEvent(.inputTransportStarted)
            case "output_playback_ready":
                onEvent(.outputPlaybackReady)
            case "proactive_opening_triggered":
                onEvent(.proactiveOpeningTriggered)
            case "input_speech_started":
                recordUserActivity(at: DispatchTime.now().uptimeNanoseconds)
                enqueueCurrentCameraImageIfEnabled(force: true)
                onEvent(.hearingUser)
            case "context_appended":
                onEvent(.contextAppended)
            case "context_rejected":
                onEvent(.contextRejected(reason: String((event.reason ?? "unknown").prefix(192))))
            case "visual_context_attached":
                onEvent(.visualContextAttached)
            case "visual_context_rejected":
                onEvent(.visualContextRejected(reason: String((event.reason ?? "unknown").prefix(192))))
            case "embodiment_mcp_ready":
                onEvent(.embodimentMCPReady)
            case "embodiment_mcp_unavailable":
                onEvent(.embodimentMCPUnavailable(reason: String((event.reason ?? "unknown").prefix(192))))
            case "input_transcript_ready":
                recordUserActivity(at: DispatchTime.now().uptimeNanoseconds)
                onEvent(.inputAccepted(characters: max(0, event.characters ?? 0)))
            case "transcript_finalized":
                guard let rawRole = event.role,
                      let role = ConversationParticipantRole(rawValue: rawRole),
                      let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                if role == .user {
                    recordUserActivity(at: DispatchTime.now().uptimeNanoseconds)
                    onEvent(.inputAccepted(characters: text.count))
                }
                onEvent(.transcriptFinalized(
                    threadID: event.threadID,
                    role: role,
                    text: String(text.prefix(8_192))
                ))
            case "response_preparing":
                onEvent(.preparingResponse)
            case "output_speech_started":
                onEvent(.responding)
            case "response_completed", "output_speech_ended":
                onEvent(.responseCompleted)
            case "ended":
                guard active || gate.phase == .starting else { continue }
                let threadID = event.threadID ?? activeThreadID
                let personEntityID = activePersonEntityID
                active = false
                gate.observeEnded()
                inactivityTimer?.cancel()
                inactivityTimer = nil
                inactivityGate.close()
                process = nil
                input = nil
                activeThreadID = nil
                activePersonEntityID = nil
                onEvent(.ended(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: String((event.reason ?? "session_ended").prefix(128))
                ))
            case "failed", "audio_rejected":
                failCurrent(reason: event.reason ?? event.event)
            default:
                break
            }
        }
    }

    private func failCurrent(reason: String) {
        let threadID = activeThreadID
        let personEntityID = activePersonEntityID
        active = false
        gate.fail(at: DispatchTime.now().uptimeNanoseconds)
        inactivityTimer?.cancel()
        inactivityTimer = nil
        inactivityGate.close()
        _ = send(["type": "stop"], reportFailure: false)
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        input = nil
        activeThreadID = nil
        activePersonEntityID = nil
        onEvent(.failed(
            threadID: threadID,
            personEntityID: personEntityID,
            reason: String(reason.prefix(192))
        ))
    }

    private func recordUserActivity(at monotonicNS: UInt64) {
        guard active, inactivityGate.recordUserActivity(at: monotonicNS) != nil else { return }
        armInactivityTimeout(at: monotonicNS)
    }

    private func armInactivityTimeout(at monotonicNS: UInt64) {
        let deadline = inactivityGate.deadlineNS ?? inactivityGate.activate(at: monotonicNS)
        inactivityTimer?.cancel()
        let remainingNS = deadline > monotonicNS ? deadline - monotonicNS : 0
        let work = DispatchWorkItem { [weak self] in
            self?.closeForUserSilence(at: DispatchTime.now().uptimeNanoseconds)
        }
        inactivityTimer = work
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(min(remainingNS, UInt64(Int.max)))),
            execute: work
        )
    }

    private func closeForUserSilence(at monotonicNS: UInt64) {
        guard active, inactivityGate.shouldClose(at: monotonicNS) else { return }
        let threadID = activeThreadID
        let personEntityID = activePersonEntityID
        active = false
        gate.observeEnded()
        inactivityGate.close()
        inactivityTimer?.cancel()
        inactivityTimer = nil
        _ = send(["type": "stop"], reportFailure: false)
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        activeThreadID = nil
        activePersonEntityID = nil
        onEvent(.ended(
            threadID: threadID,
            personEntityID: personEntityID,
            reason: "user_silence_timeout"
        ))
    }

    private func send(_ chunk: BufferedLiveAudio) {
        _ = send([
            "type": "append_audio",
            "data": chunk.data,
            "sampleRate": chunk.sampleRate,
            "samplesPerChannel": chunk.samplesPerChannel,
        ])
    }

    /// Camera frames are pulled on demand by L2 via the capture_view MCP tool
    /// by default, so the injected image is never mistaken for the user's turn.
    /// Set SOMA_L2_AUTO_INJECT_CAMERA=1 to restore per-turn auto-injection.
    private func enqueueCurrentCameraImageIfEnabled(force: Bool) {
        guard somaEnvBool("SOMA_L2_AUTO_INJECT_CAMERA", default: false) else { return }
        enqueueCurrentCameraImage(force: force)
    }

    /// A camera frame is transient input for the active turn, never a trace
    /// artifact or person-memory record. The relay already bounds the JPEG
    /// cadence; this guard prevents an audio transport retry from duplicating
    /// the same visual item in one instant.
    private func enqueueCurrentCameraImage(force: Bool) {        guard active,
              let currentCameraImageDataURI,
              let dataURI = currentCameraImageDataURI(),
              dataURI.utf8.count <= 4 * 1_048_576 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now >= lastVisualContextNS + 500_000_000 else { return }
        lastVisualContextNS = now
        send([
            "type": "append_image",
            "data": dataURI,
        ])
    }

    @discardableResult
    private func send(_ object: [String: Any], reportFailure: Bool = true) -> Bool {
        guard let input,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do {
            try input.write(contentsOf: data)
            try input.write(contentsOf: Data([0x0A]))
            return true
        } catch {
            guard reportFailure else { return false }
            let threadID = activeThreadID
            let personEntityID = activePersonEntityID
            self.input = nil
            active = false
            gate.fail(at: DispatchTime.now().uptimeNanoseconds)
            if let process, process.isRunning { process.terminate() }
            self.process = nil
            activeThreadID = nil
            activePersonEntityID = nil
            if !stopped {
                onEvent(.failed(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: "live_voice_control_pipe_failed"
                ))
            }
            return false
        }
    }

    private func helperURL() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SOMA_LIVE_VOICE_HELPER"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent("soma-live-voice"),
            executableURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/soma-live-voice"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func contextText(_ context: CodexInteractionContext) -> String {
        var lines = [
            "SOMA interaction context (machine observation, not user speech):",
            "privacy_scope: \(context.privacyScope)",
        ]
        if let value = context.situationSummary { lines.append("situation: \(value)") }
        if let value = context.identityReference { lines.append("identity: \(value)") }
        if context.personContextAvailable, let value = context.personEntityID {
            lines.append("person_context_reference: \(value.uuidString.lowercased())")
        }
        if let value = context.sessionCapability { lines.append("soma_session_token: \(value)") }
        if let value = context.interactionAuthority { lines.append("interaction_authority: \(value.rawValue)") }
        if let value = context.personMemoryMission {
            lines.append("person_memory_mission_required: \(value.missingRequiredKeys.joined(separator: ","))")
        }
        if let value = context.preferredLanguageTag { lines.append("preferred_language: \(value)") }
        if let value = context.languageStartInstruction { lines.append("l1_language_instruction: \(value)") }
        if let value = context.rapportSummary { lines.append("rapport: \(value)") }
        if let value = context.embodimentSummary { lines.append("embodiment: \(value)") }
        if !context.activeTaskSummaries.isEmpty {
            lines.append("active_tasks: \(context.activeTaskSummaries.joined(separator: " | "))")
        }
        if !context.memorySummaries.isEmpty {
            lines.append("memory: \(context.memorySummaries.joined(separator: " | "))")
        }
        return String(lines.joined(separator: "\n").prefix(24_000))
    }

    private static func pcm16Data(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = Int16(
                max(Double(Int16.min), min(Double(Int16.max), Double(sample) * Double(Int16.max)))
            ).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Bridges the latest ephemeral L1 visual interpretation into an active Live
/// conversation without persisting or forwarding camera pixels. Repeated
/// identical scene descriptions are suppressed so a static room does not
/// consume conversation context every refresh cycle.
final class LiveVisualContextRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: String?
    private var lastForwarded: String?
    private var sink: (@Sendable (String) -> Void)?

    func record(_ cue: L1AuxiliarySemanticCue) {
        let socialPresence = String(format: "%.2f", cue.socialPresence)
        let confidence = String(format: "%.2f", cue.confidence)
        let text = String(
            "Current camera context (L1 visual interpretation, not user speech): "
                + "\(cue.summary) Situation=\(cue.situation.rawValue); "
                + "social_presence=\(socialPresence); confidence=\(confidence)."
        ).prefix(512)
        let bounded = String(text)
        lock.lock()
        latest = bounded
        let shouldForward = bounded != lastForwarded
        if shouldForward { lastForwarded = bounded }
        let activeSink = sink
        lock.unlock()
        if shouldForward { activeSink?(bounded) }
    }

    func attach(to launcher: AppServerLiveVoiceLauncher) {
        lock.lock()
        sink = { [weak launcher] text in launcher?.appendContext(text) }
        lock.unlock()
    }

    var latestSummary: String? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

func testAppServerLiveVoiceLauncher() -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let result = BlockingLiveVoiceTestResult()
    let launcher = AppServerLiveVoiceLauncher { event in
        switch event {
        case .active:
            result.set("active")
            semaphore.signal()
        case let .failed(_, _, reason):
            result.set("failed:\(reason)")
            semaphore.signal()
        case .launchRequested, .inputTransportStarted, .outputPlaybackReady, .proactiveOpeningTriggered, .hearingUser,
             .contextAppended, .contextRejected, .visualContextAttached, .visualContextRejected,
             .embodimentMCPReady, .embodimentMCPUnavailable, .inputAccepted,
             .transcriptFinalized, .preparingResponse, .responding, .responseCompleted, .ended:
            break
        }
    }
    launcher.startIfNeeded(
        authorization: "explicit_test",
        context: nil,
        at: DispatchTime.now().uptimeNanoseconds
    )
    _ = semaphore.wait(timeout: .now() + 25)
    let value = result.value ?? "timeout"
    launcher.stop()
    return value
}

private final class BlockingLiveVoiceTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    func set(_ value: String) {
        lock.lock()
        if storedValue == nil { storedValue = value }
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
