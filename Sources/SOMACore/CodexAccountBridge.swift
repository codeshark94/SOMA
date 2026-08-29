import Foundation

/// The bounded situational projection supplied to an L2 Codex turn. Canonical
/// memory rows and biometric material stay in their owning local services.
public struct CodexInteractionContext: Codable, Equatable, Sendable {
    public let situationSummary: String?
    public let identityReference: String?
    /// Opaque local person reference used only as a parameter to SOMA's
    /// person-context MCP tools. It is not a name or biometric identifier.
    public let personEntityID: UUID?
    /// An unrecognized speaker can receive interaction-scoped embodiment
    /// authority without gaining a persistent person-memory record.
    public let personContextAvailable: Bool
    /// A short-lived local MCP capability for this interaction. It never
    /// leaves developer context, trace output, or persistent memory.
    public let sessionCapability: String?
    public let interactionAuthority: SOMAInteractionAuthority?
    /// Present only while the current participant has an unsatisfied social
    /// information requirement. Completed missions are omitted entirely.
    public let personMemoryMission: PersonContextMission?
    public let preferredLanguageTag: String?
    public let languageStartInstruction: String?
    public let rapportSummary: String?
    public let activeTaskSummaries: [String]
    public let memorySummaries: [String]
    public let embodimentSummary: String?
    public let privacyScope: String

    public init(
        situationSummary: String? = nil,
        identityReference: String? = nil,
        personEntityID: UUID? = nil,
        personContextAvailable: Bool? = nil,
        sessionCapability: String? = nil,
        interactionAuthority: SOMAInteractionAuthority? = nil,
        personMemoryMission: PersonContextMission? = nil,
        preferredLanguageTag: String? = nil,
        languageStartInstruction: String? = nil,
        rapportSummary: String? = nil,
        activeTaskSummaries: [String] = [],
        memorySummaries: [String] = [],
        embodimentSummary: String? = nil,
        privacyScope: String = "interaction_scoped"
    ) throws {
        self.situationSummary = try Self.optional(situationSummary, maximumCount: 8_192)
        // Identity context is a bounded local semantic description, not a
        // biometric payload. A normal L1 proactive description can exceed a
        // short identifier limit; rejecting it would discard the complete
        // interaction packet, including its live-session capability.
        self.identityReference = try Self.optional(identityReference, maximumCount: 512)
        self.personEntityID = personEntityID
        self.personContextAvailable = personContextAvailable ?? (personEntityID != nil)
        if let sessionCapability {
            guard sessionCapability.count == 36,
                  sessionCapability.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "-"
                  }) else {
                throw CodexAccountBridgeError.invalidContext
            }
            self.sessionCapability = sessionCapability.lowercased()
        } else {
            self.sessionCapability = nil
        }
        guard (personEntityID == nil) == (self.sessionCapability == nil) else {
            throw CodexAccountBridgeError.invalidContext
        }
        guard !self.personContextAvailable || personEntityID != nil else {
            throw CodexAccountBridgeError.invalidContext
        }
        guard self.sessionCapability == nil || interactionAuthority != nil else {
            throw CodexAccountBridgeError.invalidContext
        }
        self.interactionAuthority = interactionAuthority
        self.personMemoryMission = self.personContextAvailable && personMemoryMission?.isSatisfied == false
            ? personMemoryMission
            : nil
        self.preferredLanguageTag = try Self.optional(preferredLanguageTag, maximumCount: 35)
        self.languageStartInstruction = try Self.optional(languageStartInstruction, maximumCount: 1_024)
        self.rapportSummary = try Self.optional(rapportSummary, maximumCount: 2_048)
        self.activeTaskSummaries = try Self.list(activeTaskSummaries, maximumItems: 16, maximumCount: 1_024)
        self.memorySummaries = try Self.list(memorySummaries, maximumItems: 24, maximumCount: 1_024)
        self.embodimentSummary = try Self.optional(embodimentSummary, maximumCount: 2_048)
        guard !privacyScope.isEmpty, privacyScope.count <= 96 else {
            throw CodexAccountBridgeError.invalidContext
        }
        self.privacyScope = privacyScope
    }

    private enum CodingKeys: String, CodingKey {
        case situationSummary
        case identityReference
        case personEntityID
        case personContextAvailable
        case sessionCapability
        case interactionAuthority
        case personMemoryMission
        case preferredLanguageTag
        case languageStartInstruction
        case rapportSummary
        case activeTaskSummaries
        case memorySummaries
        case embodimentSummary
        case privacyScope
    }

    /// Older locally persisted bridge requests did not carry the
    /// person-context availability bit. Their previous meaning was exactly
    /// the default: a supplied person reference has person-context access.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            situationSummary: try values.decodeIfPresent(String.self, forKey: .situationSummary),
            identityReference: try values.decodeIfPresent(String.self, forKey: .identityReference),
            personEntityID: try values.decodeIfPresent(UUID.self, forKey: .personEntityID),
            personContextAvailable: try values.decodeIfPresent(Bool.self, forKey: .personContextAvailable),
            sessionCapability: try values.decodeIfPresent(String.self, forKey: .sessionCapability),
            interactionAuthority: try values.decodeIfPresent(SOMAInteractionAuthority.self, forKey: .interactionAuthority),
            personMemoryMission: try values.decodeIfPresent(PersonContextMission.self, forKey: .personMemoryMission),
            preferredLanguageTag: try values.decodeIfPresent(String.self, forKey: .preferredLanguageTag),
            languageStartInstruction: try values.decodeIfPresent(String.self, forKey: .languageStartInstruction),
            rapportSummary: try values.decodeIfPresent(String.self, forKey: .rapportSummary),
            activeTaskSummaries: try values.decodeIfPresent([String].self, forKey: .activeTaskSummaries) ?? [],
            memorySummaries: try values.decodeIfPresent([String].self, forKey: .memorySummaries) ?? [],
            embodimentSummary: try values.decodeIfPresent(String.self, forKey: .embodimentSummary),
            privacyScope: try values.decodeIfPresent(String.self, forKey: .privacyScope) ?? "interaction_scoped"
        )
    }

    private static func optional(_ value: String?, maximumCount: Int) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maximumCount else {
            throw CodexAccountBridgeError.invalidContext
        }
        return normalized
    }

    private static func list(
        _ values: [String],
        maximumItems: Int,
        maximumCount: Int
    ) throws -> [String] {
        guard values.count <= maximumItems else {
            throw CodexAccountBridgeError.invalidContext
        }
        return try values.map { value in
            guard let normalized = try optional(value, maximumCount: maximumCount) else {
                throw CodexAccountBridgeError.invalidContext
            }
            return normalized
        }
    }
}

/// JSONL input accepted by `soma-codex-bridge`. Supplying a thread ID resumes
/// an interaction after the bridge process restarts; otherwise the bridge
/// keeps the thread ID associated with the interaction in memory.
public struct CodexAccountTurnRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let turn: CodexInteractionTurn
    public let context: CodexInteractionContext
    public let resumeCodexThreadID: String?

    public init(
        turn: CodexInteractionTurn,
        context: CodexInteractionContext,
        resumeCodexThreadID: String? = nil
    ) throws {
        if let resumeCodexThreadID {
            guard Self.validIdentifier(resumeCodexThreadID) else {
                throw CodexAccountBridgeError.invalidThreadIdentifier
            }
        }
        schemaVersion = 1
        self.turn = turn
        self.context = context
        self.resumeCodexThreadID = resumeCodexThreadID
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw CodexAccountBridgeError.invalidContext
        }
        _ = try CodexInteractionTurn(
            interactionID: turn.interactionID,
            turnID: turn.turnID,
            transcript: turn.transcript,
            languageTag: turn.languageTag,
            speechStartedAtNS: turn.speechStartedAtNS,
            transcriptFinalizedAtNS: turn.transcriptFinalizedAtNS,
            evidenceIDs: turn.evidenceIDs,
            contextPacketReference: turn.contextPacketReference
        )
        _ = try CodexInteractionContext(
            situationSummary: context.situationSummary,
            identityReference: context.identityReference,
            personEntityID: context.personEntityID,
            sessionCapability: context.sessionCapability,
            interactionAuthority: context.interactionAuthority,
            personMemoryMission: context.personMemoryMission,
            preferredLanguageTag: context.preferredLanguageTag,
            languageStartInstruction: context.languageStartInstruction,
            rapportSummary: context.rapportSummary,
            activeTaskSummaries: context.activeTaskSummaries,
            memorySummaries: context.memorySummaries,
            embodimentSummary: context.embodimentSummary,
            privacyScope: context.privacyScope
        )
        if let resumeCodexThreadID,
           !Self.validIdentifier(resumeCodexThreadID) {
            throw CodexAccountBridgeError.invalidThreadIdentifier
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }
}

public struct CodexCLIUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int

    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningOutputTokens = max(reasoningOutputTokens, 0)
    }
}

public struct CodexCLIResult: Codable, Equatable, Sendable {
    public let threadID: String
    public let assistantText: String
    public let usage: CodexCLIUsage?

    public init(threadID: String, assistantText: String, usage: CodexCLIUsage?) throws {
        let text = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty, threadID.count <= 128,
              !text.isEmpty, text.count <= 131_072 else {
            throw CodexAccountBridgeError.invalidCLIResult
        }
        self.threadID = threadID
        self.assistantText = text
        self.usage = usage
    }
}

public enum CodexAccountBridgeError: Error, Equatable {
    case invalidContext
    case invalidThreadIdentifier
    case invalidCLIResult
    case malformedCLIEvent
    case incompleteCLIResult
}

/// Produces the complete, bounded L2 input. A transcript is explicitly marked
/// as user content so it cannot be confused with sensor or memory provenance.
public enum CodexAccountPromptBuilder {
    public static func prompt(for request: CodexAccountTurnRequest) -> String {
        let turn = request.turn
        let context = request.context
        let tasks = context.activeTaskSummaries.isEmpty
            ? "- none"
            : context.activeTaskSummaries.map { "- \($0)" }.joined(separator: "\n")
        let memories = context.memorySummaries.isEmpty
            ? "- none"
            : context.memorySummaries.map { "- \($0)" }.joined(separator: "\n")
        let evidence = turn.evidenceIDs.isEmpty
            ? "none"
            : turn.evidenceIDs.joined(separator: ", ")

        return """
        You are SOMA L2, the human-interaction, executive-reasoning, and task layer.
        Treat the transcript as the user's current utterance. When an explicit preferred response language is supplied, use it unless the user clearly switches language or asks otherwise; otherwise answer naturally in the user's language. This response will normally be spoken aloud, so prefer one or two concise sentences unless the user requests detail. You may use preceding turns in this same interaction as conversational context. Use only the supplied scoped context for sensor observations, identity, canonical memory, tasks, and embodiment state; state uncertainty instead of inventing them. Permitted SOMA MCP perception, memory, and reversible embodiment calls may be initiated according to the cognitive tool policy below. File, shell, network, service, system, and other external actions still require an explicit user request and applicable authority. Return only the response intended for the user.

        \(L2CognitiveToolPolicy.instruction)

        Interaction ID: \(turn.interactionID)
        Turn ID: \(turn.turnID)
        Language tag: \(turn.languageTag ?? "und")
        Evidence IDs: \(evidence)
        Privacy scope: \(context.privacyScope)
        Identity reference: \(context.identityReference ?? "unknown")
        Preferred response language: \(context.preferredLanguageTag ?? "unspecified")
        L1 language instruction: \(context.languageStartInstruction ?? "unavailable")
        Situation: \(context.situationSummary ?? "unavailable")
        Rapport: \(context.rapportSummary ?? "unavailable")
        Embodiment: \(context.embodimentSummary ?? "unavailable")

        Active tasks:
        \(tasks)

        Scoped memory:
        \(memories)

        User transcript:
        \(turn.transcript)
        """
    }
}

/// Parses the documented JSONL mode of `codex exec` without depending on
/// human-readable stderr. Unknown event types are ignored for forward
/// compatibility; a completed assistant message and thread ID are mandatory.
public enum CodexCLIJSONLParser {
    public static func parse(_ data: Data) throws -> CodexCLIResult {
        let decoder = JSONDecoder()
        var threadID: String?
        var assistantMessages: [String] = []
        var usage: CodexCLIUsage?

        for line in data.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) where !line.isEmpty {
            let event: Event
            do {
                event = try decoder.decode(Event.self, from: Data(line))
            } catch {
                throw CodexAccountBridgeError.malformedCLIEvent
            }
            if event.type == "thread.started", let value = event.threadID {
                threadID = value
            }
            if event.type == "item.completed",
               event.item?.type == "agent_message",
               let text = event.item?.text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantMessages.append(text)
            }
            if event.type == "turn.completed", let raw = event.usage {
                usage = CodexCLIUsage(
                    inputTokens: raw.inputTokens ?? 0,
                    cachedInputTokens: raw.cachedInputTokens ?? 0,
                    outputTokens: raw.outputTokens ?? 0,
                    reasoningOutputTokens: raw.reasoningOutputTokens ?? 0
                )
            }
        }

        guard let threadID, !assistantMessages.isEmpty else {
            throw CodexAccountBridgeError.incompleteCLIResult
        }
        return try CodexCLIResult(
            threadID: threadID,
            assistantText: assistantMessages.joined(separator: "\n"),
            usage: usage
        )
    }

    private struct Event: Decodable {
        let type: String
        let threadID: String?
        let item: Item?
        let usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case type
            case threadID = "thread_id"
            case item
            case usage
        }
    }

    private struct Item: Decodable {
        let type: String
        let text: String?
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
        }
    }
}
