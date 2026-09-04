import Foundation
import SOMACore

/// A low-latency L1 companion for an already-open Live Voice session. It does
/// not speak and cannot execute tools. It watches finalized turns and actual
/// MCP completions, then emits a tightly validated recommendation that the
/// active L2 session may consume before speaking. Hard real-time controls such
/// as ending the session remain owned by the local conversation host.
final class L1LiveConversationToolSupervisor: @unchecked Sendable {
    typealias HealthHandler = @Sendable (String, String) -> Void
    typealias AdviceHandler = @Sendable (L1LiveToolAdvice, String) -> Void
    typealias InferenceHandler = @Sendable (
        L1LiveToolAdviceRequest,
        @escaping @Sendable (Result<L1LiveToolAdvice, Error>) -> Void
    ) -> Void

    private struct PendingAdvice: Equatable {
        let turnID: UUID
        let toolName: String
    }

    private let queue = DispatchQueue(label: "soma.l1.live-tool-supervisor", qos: .userInitiated)
    private let infer: InferenceHandler
    private let onHealth: HealthHandler
    private let onAdvice: AdviceHandler

    private var activeThreadID: String?
    private var mcpAvailable = false
    private var recentConversation: [L1LiveConversationTurn] = []
    private var currentTurnID: UUID?
    private var currentTranscript = ""
    private var currentTurnFinalized = false
    private var currentTurnArchived = false
    private var successfulTools = Set<String>()
    private var pendingAdvice: PendingAdvice?
    private var inferenceInFlight = false
    private var generation: UInt64 = 0
    private var stopped = false

    init(
        infer: @escaping InferenceHandler,
        onHealth: @escaping HealthHandler,
        onAdvice: @escaping AdviceHandler
    ) {
        self.infer = infer
        self.onHealth = onHealth
        self.onAdvice = onAdvice
        onHealth(
            "configured",
            "backend=primary_l1_31b; protocol=ollama_native_tool_calls; input=realtime_wire_participant_turn; scheduling=live_tool_before_executive_event_periodic; execution=external_work_controller_other_tools_l2"
        )
    }

    func begin(threadID: String) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            generation &+= 1
            inferenceInFlight = false
            activeThreadID = String(threadID.prefix(128))
            recentConversation.removeAll(keepingCapacity: true)
            resetTurn()
        }
    }

    func setMCPAvailable(_ available: Bool) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            mcpAvailable = available
        }
    }

    func observeUserTurn(threadID: String, transcript: String) {
        queue.async { [weak self] in
            guard let self, !stopped, mcpAvailable,
                  activeThreadID == threadID else { return }
            let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            let finalTranscript = String(normalized.prefix(4_096))
            beginTurn(transcript: finalTranscript)
            submitCurrentTurn(generation: generation)
        }
    }

    func observeAssistantTurn(threadID: String, transcript: String) {
        queue.async { [weak self] in
            guard let self, !stopped, activeThreadID == threadID else { return }
            appendTurn(.init(role: .assistant, text: transcript))
            currentTurnFinalized = true
        }
    }

    func observeToolCall(tool: String, status: String) {
        queue.async { [weak self] in
            guard let self, !stopped, currentTurnID != nil else { return }
            let boundedTool = String(tool.prefix(96))
            guard L2CognitiveToolPolicy.knownToolNames.contains(boundedTool) else { return }
            if status == "completed" {
                successfulTools.insert(boundedTool)
                if pendingAdvice?.toolName == boundedTool {
                    let turn = pendingAdvice?.turnID.uuidString.lowercased() ?? "unknown"
                    pendingAdvice = nil
                    onHealth("fulfilled", "turn=\(turn); tool=\(boundedTool)")
                }
            }
        }
    }

    func end(threadID: String?) {
        queue.async { [weak self] in
            guard let self, !stopped,
                  threadID == nil || activeThreadID == threadID else { return }
            generation &+= 1
            inferenceInFlight = false
            activeThreadID = nil
            recentConversation.removeAll(keepingCapacity: false)
            resetTurn()
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            generation &+= 1
            inferenceInFlight = false
            activeThreadID = nil
            recentConversation.removeAll(keepingCapacity: false)
            resetTurn()
        }
    }

    private func submitCurrentTurn(generation expectedGeneration: UInt64) {
        guard let threadID = activeThreadID,
              let turnID = currentTurnID else { return }
        let request = L1LiveToolAdviceRequest(
            threadID: threadID,
            turnID: turnID,
            latestUserTranscript: currentTranscript,
            recentConversation: recentConversation,
            availableTools: Array(L2CognitiveToolPolicy.knownToolNames),
            toolsAlreadyCalled: Array(successfulTools)
        )
        if let advice = L1LiveEpistemicReflexRouter.route(request) {
            let tool = advice.toolName ?? "none"
            onHealth("reflex_route", "turn=\(turnID.uuidString.lowercased()); tool=\(tool); finalized=true")
            apply(advice, latencyMS: 0)
            return
        }
        inferenceInFlight = true
        let startedNS = DispatchTime.now().uptimeNanoseconds
        onHealth("started", "turn=\(turnID.uuidString.lowercased()); backend=primary_l1_31b; protocol=ollama_native_tool_calls")
        infer(request) { [weak self] outcome in
            self?.queue.async { [weak self] in
                guard let self, !stopped,
                      generation == expectedGeneration,
                      currentTurnID == request.turnID,
                      activeThreadID == request.threadID else { return }
                inferenceInFlight = false
                let latencyMS = Double(DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
                guard case let .success(advice) = outcome else {
                    let reason: String
                    if case let .failure(error) = outcome {
                        reason = error.localizedDescription
                    } else {
                        reason = "primary_l1_inference_failed"
                    }
                    onHealth("failed", "turn=\(turnID.uuidString.lowercased()); reason=\(String(reason.prefix(160))); latency_ms=\(String(format: "%.1f", latencyMS))")
                    return
                }
                guard request.latestUserTranscript == currentTranscript else {
                    onHealth("held", "turn=\(turnID.uuidString.lowercased()); reason=transcript_advanced")
                    if currentTurnFinalized {
                        generation &+= 1
                        submitCurrentTurn(generation: generation)
                    }
                    return
                }
                apply(advice, latencyMS: latencyMS)
            }
        }
    }

    private func appendTurn(_ turn: L1LiveConversationTurn) {
        recentConversation.append(turn)
        if recentConversation.count > 8 {
            recentConversation.removeFirst(recentConversation.count - 8)
        }
    }

    private func beginTurn(transcript: String) {
        generation &+= 1
        inferenceInFlight = false
        currentTurnID = UUID()
        currentTranscript = transcript
        currentTurnFinalized = true
        currentTurnArchived = false
        successfulTools.removeAll(keepingCapacity: true)
        pendingAdvice = nil
        archiveCurrentTurnIfNeeded()
    }

    private func archiveCurrentTurnIfNeeded() {
        guard currentTurnFinalized, !currentTurnArchived else { return }
        currentTurnArchived = true
        appendTurn(.init(role: .user, text: currentTranscript))
    }

    private func apply(_ advice: L1LiveToolAdvice, latencyMS: Double? = nil) {
        guard advice.action == .recommendTool,
              let tool = advice.toolName else {
            onHealth(
                "no_assist",
                "turn=\(advice.turnID.uuidString.lowercased())\(latencyMS.map { "; latency_ms=\(String(format: "%.1f", $0))" } ?? "")"
            )
            return
        }
        guard !successfulTools.contains(tool) else {
            onHealth("held", "turn=\(advice.turnID.uuidString.lowercased()); reason=tool_already_completed; tool=\(tool)")
            return
        }
        pendingAdvice = .init(turnID: advice.turnID, toolName: tool)
        onHealth(
            "recommended",
            "turn=\(advice.turnID.uuidString.lowercased()); tool=\(tool); confidence=\(String(format: "%.2f", advice.confidence))\(latencyMS.map { "; latency_ms=\(String(format: "%.1f", $0))" } ?? "")"
        )
        onAdvice(advice, currentTranscript)
        if let pendingAdvice { armFulfillmentCheck(for: pendingAdvice) }
    }

    private func resetTurn() {
        currentTurnID = nil
        currentTranscript = ""
        currentTurnFinalized = false
        currentTurnArchived = false
        successfulTools.removeAll(keepingCapacity: false)
        pendingAdvice = nil
    }

    private func armFulfillmentCheck(for expected: PendingAdvice) {
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !stopped, pendingAdvice == expected else { return }
            pendingAdvice = nil
            onHealth(
                "unfulfilled",
                "turn=\(expected.turnID.uuidString.lowercased()); tool=\(expected.toolName)"
            )
        }
    }

}
