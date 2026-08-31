import Foundation

public struct L1LiveConversationTurn: Codable, Equatable, Sendable {
    public let role: ConversationParticipantRole
    public let text: String

    public init(role: ConversationParticipantRole, text: String) {
        self.role = role
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096))
    }
}

public struct L1LiveToolAdviceRequest: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let threadID: String
    public let turnID: UUID
    public let observedAt: Date
    public let latestUserTranscript: String
    public let recentConversation: [L1LiveConversationTurn]
    public let availableTools: [String]
    public let toolsAlreadyCalled: [String]

    public init(
        cycleID: UUID = UUID(),
        threadID: String,
        turnID: UUID = UUID(),
        observedAt: Date = Date(),
        latestUserTranscript: String,
        recentConversation: [L1LiveConversationTurn] = [],
        availableTools: [String],
        toolsAlreadyCalled: [String] = []
    ) {
        self.cycleID = cycleID
        self.threadID = String(threadID.prefix(128))
        self.turnID = turnID
        self.observedAt = observedAt
        self.latestUserTranscript = String(
            latestUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096)
        )
        self.recentConversation = Array(recentConversation.suffix(8))
        self.availableTools = Array(Set(availableTools).intersection(L2CognitiveToolPolicy.knownToolNames))
            .sorted()
        self.toolsAlreadyCalled = Array(Set(toolsAlreadyCalled).intersection(self.availableTools)).sorted()
    }
}

public enum L1LiveToolAdviceAction: String, Codable, CaseIterable, Sendable {
    case noAssist = "no_assist"
    case recommendTool = "recommend_tool"
}

public struct L1LiveToolAdvice: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let threadID: String
    public let turnID: UUID
    public let action: L1LiveToolAdviceAction
    public let toolName: String?
    public let groundingQuote: String?
    public let confidence: Double
    public let rationale: String

    public init(
        cycleID: UUID,
        threadID: String,
        turnID: UUID,
        action: L1LiveToolAdviceAction,
        toolName: String? = nil,
        groundingQuote: String? = nil,
        confidence: Double,
        rationale: String
    ) {
        self.cycleID = cycleID
        self.threadID = String(threadID.prefix(128))
        self.turnID = turnID
        self.action = action
        self.toolName = toolName.map { String($0.prefix(96)) }
        self.groundingQuote = groundingQuote.map { String($0.prefix(512)) }
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.rationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
    }
}

public enum L1LiveToolAdviceResponseError: Error, Equatable, Sendable {
    case malformedJSON
    case validationFailed([String])
}

extension L1LiveToolAdviceResponseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            "Malformed live tool-advice JSON."
        case let .validationFailed(failures):
            "Live tool advice validation failed: \(failures.joined(separator: "; "))."
        }
    }
}

public enum L1LiveToolAdviceResponseDecoder {
    public static func decode(_ data: Data, for request: L1LiveToolAdviceRequest) throws -> L1LiveToolAdvice {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw L1LiveToolAdviceResponseError.malformedJSON
        }
        let allowedKeys: Set<String> = [
            "cycle_id", "thread_id", "turn_id", "action", "tool_name",
            "grounding_quote", "confidence", "rationale",
        ]
        var failures: [String] = []
        if let unknown = object.keys.first(where: { !allowedKeys.contains($0) }) {
            failures.append("unknown field: \(unknown)")
        }
        guard let cycleID = (object["cycle_id"] as? String).flatMap(UUID.init(uuidString:)),
              let threadID = object["thread_id"] as? String,
              let turnID = (object["turn_id"] as? String).flatMap(UUID.init(uuidString:)),
              let rawAction = object["action"] as? String,
              let action = L1LiveToolAdviceAction(rawValue: rawAction),
              let confidence = object["confidence"] as? NSNumber,
              let rationale = object["rationale"] as? String else {
            throw L1LiveToolAdviceResponseError.malformedJSON
        }
        let toolName = object["tool_name"] as? String
        let groundingQuote = object["grounding_quote"] as? String
        if cycleID != request.cycleID { failures.append("cycle ID mismatch") }
        if threadID != request.threadID { failures.append("thread ID mismatch") }
        if turnID != request.turnID { failures.append("turn ID mismatch") }
        if rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("rationale is required")
        }
        switch action {
        case .noAssist:
            if toolName != nil || groundingQuote != nil {
                failures.append("no_assist cannot carry a tool or grounding quote")
            }
        case .recommendTool:
            guard let toolName, request.availableTools.contains(toolName) else {
                failures.append("recommended tool is unavailable")
                break
            }
            if request.toolsAlreadyCalled.contains(toolName) {
                failures.append("recommended tool already ran for this turn")
            }
            guard let groundingQuote,
                  Self.containsGroundingQuote(
                    groundingQuote,
                    in: request.latestUserTranscript
                  ) else {
                failures.append("grounding quote is not present in the latest user transcript")
                break
            }
        }
        guard failures.isEmpty else {
            throw L1LiveToolAdviceResponseError.validationFailed(failures)
        }
        return L1LiveToolAdvice(
            cycleID: cycleID,
            threadID: threadID,
            turnID: turnID,
            action: action,
            toolName: toolName,
            groundingQuote: groundingQuote,
            confidence: confidence.doubleValue,
            rationale: rationale
        )
    }

    private static func containsGroundingQuote(_ rawQuote: String, in rawTranscript: String) -> Bool {
        let quote = normalized(rawQuote)
        let transcript = normalized(rawTranscript)
        return quote.count >= 2 && transcript.contains(quote)
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
