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

/// Decodes Ollama's native `/api/chat` tool-call envelope into SOMA's bounded
/// advisory contract. Authoritative request identifiers are supplied locally;
/// the model selects at most one function and must ground it in the latest
/// participant transcript.
public enum L1LiveToolAdviceOllamaDecoder {
    public static func decode(
        _ data: Data,
        for request: L1LiveToolAdviceRequest
    ) throws -> L1LiveToolAdvice {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else {
            throw L1LiveToolAdviceResponseError.malformedJSON
        }
        let calls = message["tool_calls"] as? [[String: Any]] ?? []
        guard calls.count <= 1 else {
            throw L1LiveToolAdviceResponseError.validationFailed([
                "exactly zero or one native tool call is allowed",
            ])
        }
        guard let call = calls.first else {
            return L1LiveToolAdvice(
                cycleID: request.cycleID,
                threadID: request.threadID,
                turnID: request.turnID,
                action: .noAssist,
                confidence: 1,
                rationale: "The primary L1 model selected no tool."
            )
        }
        guard let function = call["function"] as? [String: Any],
              let name = function["name"] as? String else {
            throw L1LiveToolAdviceResponseError.malformedJSON
        }
        let arguments: [String: Any]
        if let object = function["arguments"] as? [String: Any] {
            arguments = object
        } else if let raw = function["arguments"] as? String,
                  let encoded = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            arguments = object
        } else {
            arguments = [:]
        }
        guard Set(arguments.keys).isSubset(of: ["grounding_quote"]) else {
            throw L1LiveToolAdviceResponseError.validationFailed([
                "native tool arguments may contain only grounding_quote",
            ])
        }
        let object: [String: Any] = [
            "cycle_id": request.cycleID.uuidString.lowercased(),
            "thread_id": request.threadID,
            "turn_id": request.turnID.uuidString.lowercased(),
            "action": L1LiveToolAdviceAction.recommendTool.rawValue,
            "tool_name": name,
            "grounding_quote": arguments["grounding_quote"] ?? NSNull(),
            "confidence": 0.85,
            "rationale": "The primary L1 model selected this function through Ollama native tool calling.",
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
            throw L1LiveToolAdviceResponseError.malformedJSON
        }
        return try L1LiveToolAdviceResponseDecoder.decode(encoded, for: request)
    }
}

/// Routes narrow, read-only conversational intents without placing a remote
/// model on the first-audio path. Ambiguous language still goes to the primary
/// L1 model; only explicit status domains with an available canonical tool are
/// admitted here.
public enum L1LiveEpistemicReflexRouter {
    private struct Route {
        let tool: String
        let subjectCues: [String]
        let requestCues: [String]
    }

    private static let statusRequestCues = [
        "report status", "give me a status", "status report please", "what are you doing",
        "상태 보고", "상황 보고", "현황 보고", "뭐 하고 있어", "뭐하는 중",
        "状态报告", "报告状态", "现在在做什么", "状況報告", "状態報告", "何をしている",
    ]

    private static let routes: [Route] = [
        Route(
            tool: "get_robot_body_state",
            subjectCues: [
                "camera", "gimbal", "tracking", "track", "body",
                "카메라", "짐벌", "추적", "몸 상태",
                "摄像头", "云台", "跟踪", "カメラ", "ジンバル", "追跡",
            ],
            requestCues: statusRequestCues
        ),
        Route(
            tool: "list_hermes_tasks",
            subjectCues: [
                "hermes", "delegated task", "background task", "worker task",
                "헤르메스", "맡긴 작업", "위임 작업", "백그라운드 작업",
                "委托任务", "后台任务", "委任タスク", "バックグラウンド作業",
            ],
            requestCues: statusRequestCues
        ),
        Route(
            tool: "get_activity_overview",
            subjectCues: [],
            requestCues: statusRequestCues
        ),
    ]

    public static func route(_ request: L1LiveToolAdviceRequest) -> L1LiveToolAdvice? {
        let transcript = request.latestUserTranscript
        let foldedTranscript = fold(transcript)
        guard !foldedTranscript.isEmpty else { return nil }
        if request.availableTools.contains("capture_view"),
           !request.toolsAlreadyCalled.contains("capture_view"),
           requiresCurrentCameraEvidence(transcript: foldedTranscript) {
            return L1LiveToolAdvice(
                cycleID: request.cycleID,
                threadID: request.threadID,
                turnID: request.turnID,
                action: .recommendTool,
                toolName: "capture_view",
                groundingQuote: transcript,
                confidence: 1,
                rationale: "The participant explicitly requested current camera evidence."
            )
        }
        for route in routes {
            guard request.availableTools.contains(route.tool),
                  !request.toolsAlreadyCalled.contains(route.tool),
                  route.subjectCues.isEmpty || route.subjectCues.contains(where: {
                      foldedTranscript.contains(fold($0))
                  }),
                  let cue = route.requestCues.first(where: {
                      foldedTranscript.contains(fold($0))
                  }),
                  let range = transcript.range(
                      of: cue,
                      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
                  ) else {
                continue
            }
            return L1LiveToolAdvice(
                cycleID: request.cycleID,
                threadID: request.threadID,
                turnID: request.turnID,
                action: .recommendTool,
                toolName: route.tool,
                groundingQuote: String(transcript[range]),
                confidence: 1,
                rationale: "Explicit read-only status intent matched the canonical domain route."
            )
        }
        return nil
    }

    /// This route is deliberately narrower than general visual language. It
    /// admits only an explicit request for what the robot camera sees now, so
    /// words such as "look" in an unrelated conversational turn cannot move or
    /// sample the camera. Reframing remains an L2-authored MCP action.
    public static func requiresCurrentCameraEvidence(transcript: String) -> Bool {
        let transcript = fold(transcript)
        let exactRequests = [
            "whatdoyousee", "whatcanyousee", "whatsoncamera", "whatisoncamera",
            "canyouseeme", "doyouseeme", "howdoilook", "whoishere", "whoiswithme",
            "카메라에뭐보여", "카메라뭐보여", "지금뭐보여", "뭐가보여", "누가보여",
            "나보여", "내가보여", "나볼수있", "나를볼수있", "날볼수있",
            "저볼수있", "저를볼수있", "내모습", "어떻게보여", "누가있어",
            "你看到了什么", "摄像头里有什么", "你能看到我吗", "誰が見える", "何が見える",
            "カメラに何が映って", "私が見える",
        ]
        if exactRequests.contains(where: transcript.contains) { return true }

        let selfSubjects = [
            "iam", "im", "me", "myself",
            "내가", "나는", "난", "내모습", "나지금",
            "我在", "我现在", "私は", "私が",
        ]
        let observedActivityRequests = [
            "whatamidoing", "whatdoilooklike",
            "뭐하고있", "뭘하고있", "무엇을하고있",
            "做什么", "在干什么", "何をしている", "何してる",
        ]
        return selfSubjects.contains(where: transcript.contains)
            && observedActivityRequests.contains(where: transcript.contains)
    }

    private static func fold(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
