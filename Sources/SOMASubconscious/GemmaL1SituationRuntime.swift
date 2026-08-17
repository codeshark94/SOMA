import Foundation
import SOMACore

private enum GemmaL1SituationRuntimeError: LocalizedError {
    case invalidEndpoint
    case requestEncoding
    case transport(String)
    case responseStatus(Int)
    case missingResponse
    case invalidResponse(String)
    case memoryUnavailable
    case invalidPersonContextRequest

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "l1_ollama_endpoint_invalid"
        case .requestEncoding: "l1_ollama_request_encoding_failed"
        case let .transport(message): "l1_ollama_transport_\(message)"
        case let .responseStatus(status): "l1_ollama_http_\(status)"
        case .missingResponse: "l1_ollama_response_missing"
        case let .invalidResponse(message): "l1_ollama_response_invalid_\(message)"
        case .memoryUnavailable: "person_context_memory_unavailable"
        case .invalidPersonContextRequest: "person_context_request_invalid"
        }
    }
}

struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let format: String
    let stream: Bool
    let images: [String]?
    let options: Options

    struct Options: Encodable {
        let temperature: Double
        let numPredict: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }
}

struct OllamaGenerateResponse: Decodable {
    let response: String?
}

/// A tool definition passed to Ollama's /api/chat tool-calling.
struct OllamaToolDefinition: Encodable {
    let type: String = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: Parameters

        struct Parameters: Encodable {
            let type: String = "object"
            let properties: [String: Property]
            let required: [String]
        }

        struct Property: Encodable {
            let type: String
            let description: String?
        }
    }
}

/// The tool-calling /api/chat request payload.
struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let tools: [OllamaToolDefinition]
    let stream: Bool
    let options: OllamaGenerateRequest.Options

    struct Message: Encodable {
        let role: String
        let content: String?
        let images: [String]?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content, images
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Encodable {
        let id: String
        let type: String = "function"
        let function: Call

        struct Call: Encodable {
            let name: String
            let arguments: AnyJSONValue?
        }
    }
}

/// The tool-calling /api/chat response payload.
struct OllamaChatResponse: Decodable {
    let message: Message?

    struct Message: Decodable {
        let role: String?
        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        let id: String?
        let function: Function?

        struct Function: Decodable {
            let name: String?
            /// Ollama emits arguments as a JSON object (or a string). Preserve
            /// whatever was sent so it round-trips on the echo.
            let arguments: AnyJSONValue?
        }
    }
}

/// Loose JSON value wrapper so tool arguments (objects/arrays/primitives) can
/// be decoded and re-serialized without tight typing.
enum AnyJSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSONValue])
    case array([AnyJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { self = .string(string) }
        else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let object = try? container.decode([String: AnyJSONValue].self) { self = .object(object) }
        else if let array = try? container.decode([AnyJSONValue].self) { self = .array(array) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unexpected JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// JSON string form (for the tool executor and for the assistant echo).
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// A single tool call L1 made, ready for execution.
struct L1ToolInvocation {
    let id: String
    let name: String
    let arguments: String
    let reason: String?
}

struct L1MemoryContext: Sendable {
    let projections: [RemoteMemoryProjection]
    let informationNeeds: [L1InformationNeed]
    let rapport: L1RapportContext?
    let proactiveContactPreference: ProactiveContactPreference
    let preferredLanguageTag: String?
    let contactHistory: [L1SocialContactEvent]
    let personPreferences: String
    let recalledEpisodes: [String]
}

private final class SynchronousWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func read() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Keeps the L1 cloud packet on the allowed side of the memory boundary.
/// Raw conversation, biometric identity material, and local-only records stay
/// in the encrypted journal; only marked summaries, rapport, and information
/// motives can become situation context.
/// A durable, persisted information need (open question) that L2 can resolve
/// as a mission. Mirrors L1InformationNeed but carries the memory record ID.
public struct PersistedInformationNeed: Codable, Equatable, Sendable {
    public let motiveID: UUID
    public let question: String
    public let targetEntityID: UUID?
    public let expectedInformationGain: Double
    public let createdAt: Date

    public init(
        motiveID: UUID,
        question: String,
        targetEntityID: UUID?,
        expectedInformationGain: Double,
        createdAt: Date
    ) {
        self.motiveID = motiveID
        self.question = question
        self.targetEntityID = targetEntityID
        self.expectedInformationGain = expectedInformationGain
        self.createdAt = createdAt
    }
}
final class L1MemoryContextProvider: @unchecked Sendable {
    private struct ActiveConversation {
        let archiver: ConversationTranscriptArchiver
        let startedAt: Date
        let personEntityID: UUID?
        var socialEpisode: L1ConversationContactEpisode
    }

    private let store: CognitiveMemoryStore?
    private let onHealth: @Sendable (String, String) -> Void
    private let onPreferredLanguageChanged: @Sendable (UUID, String?) -> Void
    private let onSocialContactPersisted: @Sendable (UUID) -> Void
    private let transcriptRetentionSeconds: TimeInterval
    private let preferredLanguageLock = NSLock()
    private var preferredLanguageByPersonID: [UUID: String] = [:]
    private var personContextByPersonID: [UUID: PersonContextSnapshot] = [:]
    private var personMemorySummariesByPersonID: [UUID: [String]] = [:]
    private var personInfoNeedsByPersonID: [UUID: [PersistedInformationNeed]] = [:]
    private let conversationLock = NSLock()
    private var activeConversations: [String: ActiveConversation] = [:]
    /// Every durable consequence of a finalized Live turn joins this group.
    /// Shutdown drains it before committing the episode closure, preserving the
    /// event order L1 uses for social continuity.
    private let conversationWriteGroup = DispatchGroup()
    private let embeddingClient = OllamaEmbeddingClient()
    private let embeddingCache = EpisodicEmbeddingCache()

    init(
        onHealth: @escaping @Sendable (String, String) -> Void,
        onPreferredLanguageChanged: @escaping @Sendable (UUID, String?) -> Void = { _, _ in },
        onSocialContactPersisted: @escaping @Sendable (UUID) -> Void = { _ in },
        transcriptRetentionSeconds: TimeInterval = 24 * 60 * 60
    ) {
        self.onHealth = onHealth
        self.onPreferredLanguageChanged = onPreferredLanguageChanged
        self.onSocialContactPersisted = onSocialContactPersisted
        self.transcriptRetentionSeconds = min(max(transcriptRetentionSeconds, 60 * 60), 24 * 60 * 60)
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SOMA/memory", isDirectory: true)
            let key = try OwnerOnlyInstallationSecret.loadOrCreate(
                in: directory,
                filename: "installation-key-v1.bin"
            )
            store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
            onHealth("memory_ready", "store=encrypted_local; remote_projection=policy_filtered")
        } catch {
            store = nil
            onHealth("memory_unavailable", String(error.localizedDescription.prefix(192)))
        }
    }

    func context(
        for entityID: UUID,
        createPseudonymousEntity: Bool = false
    ) async -> L1MemoryContext {
        guard let store else {
            return L1MemoryContext(
                projections: [],
                informationNeeds: [],
                rapport: nil,
                proactiveContactPreference: .unknown,
                preferredLanguageTag: nil,
                contactHistory: [],
                personPreferences: "",
                recalledEpisodes: []
            )
        }
        do {
            let now = Date()
            if createPseudonymousEntity {
                try await ensurePseudonymousEntity(entityID, in: store, at: now)
            }
            let records = try await store.query(
                .init(relatedTo: [entityID], limit: 96),
                at: now
            )
            let allowed = records.filter {
                $0.disclosure == .remoteSummaryAllowed
                    && $0.sensitivity != .biometric
                    && $0.sensitivity != .secret
            }
            let projections = allowed.map {
                RemoteMemoryProjection(
                    id: $0.id,
                    revision: $0.revision,
                    tier: $0.tier,
                    kind: $0.kind,
                    summary: $0.summary,
                    confidence: $0.confidence,
                    updatedAt: $0.updatedAt
                )
            }
            var needs = allowed.compactMap { record -> L1InformationNeed? in
                guard case let .openQuestion(question) = record.payload,
                      question.targetEntityID == entityID,
                      question.status == .open else {
                    return nil
                }
                return L1InformationNeed(
                    motiveID: record.id,
                    source: .retainedMemoryGap,
                    informationGoal: question.question,
                    expectedInformationGain: question.expectedInformationGain
                )
            }
            let relationship = records.compactMap { record -> (Date, RapportProfile)? in
                guard case let .relationship(value) = record.payload,
                      value.personEntityID == entityID else {
                    return nil
                }
                return (record.updatedAt, value.rapport)
            }.max { $0.0 < $1.0 }?.1
            let contactHistory = records.compactMap { record -> L1SocialContactEvent? in
                guard case let .situation(value) = record.payload,
                      value.participantEntityIDs.contains(entityID),
                      value.state.hasPrefix("social_contact:"),
                      let rawKind = value.state.split(separator: ":", maxSplits: 1).last,
                      let kind = L1SocialContactKind(rawValue: String(rawKind)) else {
                    return nil
                }
                return L1SocialContactEvent(
                    kind: kind,
                    occurredAt: record.updatedAt,
                    purpose: record.summary
                )
            }.sorted { $0.occurredAt > $1.occurredAt }
            let remotelyAllowedRapport = allowed.compactMap { record -> (Date, L1RapportContext)? in
                guard case let .relationship(value) = record.payload,
                      value.personEntityID == entityID else {
                    return nil
                }
                return (
                    record.updatedAt,
                    L1RapportContext(
                        familiarity: value.rapport.familiarity,
                        interactionComfort: value.rapport.interactionComfort,
                        communicationAlignment: value.rapport.communicationAlignment,
                        proactiveContact: value.rapport.proactiveContact
                    )
                )
            }.max { $0.0 < $1.0 }?.1
            let hasPreferredName = records.contains { record in
                guard case let .personFact(value) = record.payload else { return false }
                return value.personEntityID == entityID && value.key == "preferred_name"
            }
            if !hasPreferredName, needs.isEmpty {
                let goal = "Learn the person's preferred name or form of address for future respectful interaction."
                let motiveID = await ensureInformationNeed(
                    question: goal,
                    targetEntityID: entityID,
                    expectedInformationGain: 0.95,
                    sourceID: "l1_initial_social_orientation"
                )
                needs.append(L1InformationNeed(
                    motiveID: motiveID ?? UUID(),
                    source: .initialSocialOrientation,
                    informationGoal: goal,
                    expectedInformationGain: 0.95
                ))
            }
            let interestFactKeys: Set<String> = [
                "interest_profile",
                "interests",
                "favorite_topics",
                "hobbies",
            ]
            let hasInterestProfile = records.contains { record in
                guard case let .personFact(value) = record.payload else { return false }
                return value.personEntityID == entityID && interestFactKeys.contains(value.key)
            }
            if !hasInterestProfile {
                let goal = "When the situation naturally supports it, learn one enduring interest, hobby, or topic this person enjoys discussing."
                let motiveID = await ensureInformationNeed(
                    question: goal,
                    targetEntityID: entityID,
                    expectedInformationGain: 0.64,
                    sourceID: "l1_interest_discovery"
                )
                needs.append(L1InformationNeed(
                    motiveID: motiveID ?? UUID(),
                    source: .interestDiscovery,
                    informationGoal: goal,
                    expectedInformationGain: 0.64
                ))
            }
            let personContext = try await store.personContext(for: entityID, at: now)
            cachePersonContext(personContext)
            cachePersonMemorySummaries(projections.map(\.summary), for: entityID)
            let persistedNeeds = await pendingInformationNeeds(for: entityID, at: now)
            cacheInformationNeeds(persistedNeeds, for: entityID)
            let recalled = await recallEpisodes(
                entityID: entityID,
                query: personContext.preferenceDirectives().joined(separator: " "),
                at: now
            )
            return L1MemoryContext(
                projections: projections,
                informationNeeds: needs,
                rapport: remotelyAllowedRapport,
                proactiveContactPreference: relationship?.proactiveContact ?? .unknown,
                preferredLanguageTag: personContext.preferredLanguageTag,
                contactHistory: Array(contactHistory.prefix(16)),
                personPreferences: personContext.preferenceDirectives().joined(separator: " "),
                recalledEpisodes: recalled
            )
        } catch {
            onHealth("memory_unavailable", String(error.localizedDescription.prefix(192)))
            return L1MemoryContext(
                projections: [],
                informationNeeds: [],
                rapport: nil,
                proactiveContactPreference: .unknown,
                preferredLanguageTag: nil,
                contactHistory: [],
                personPreferences: "",
                recalledEpisodes: []
            )
        }
    }

    /// Semantically recalls the most relevant past episodes by embedding the
    /// query and episode narratives and ranking by cosine similarity blended
    /// with salience and recency. Falls back to recency-only ranking when the
    /// embedding model is unavailable. `entityID` optionally scopes to one
    /// person; nil recalls across all episodes.
    private func recallEpisodes(
        entityID: UUID?,
        query: String,
        limit: Int = 4,
        at date: Date
    ) async -> [String] {
        guard let store else { return [] }
        do {
            let episodes = try await store.query(
                .init(kinds: [.episode], relatedTo: entityID.map { [$0] } ?? [], limit: 200),
                at: date
            )
            guard !episodes.isEmpty else { return [] }
            let scoped = entityID != nil
            let queryText = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (scoped ? "recent meaningful conversation with this person" : "recent meaningful conversation")
                : (scoped ? "conversation with this person about \(query)" : query)
            guard let queryEmbedding = await embeddingClient.embed(queryText) else {
                return episodes
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(limit)
                    .compactMap { episodeNarrative($0) }
            }
            var scored: [(narrative: String, similarity: Float, salience: Double, updatedAt: Date)] = []
            for episode in episodes {
                guard let narrative = episodeNarrative(episode), !narrative.isEmpty else { continue }
                let embedding: [Float]?
                if let cached = embeddingCache.embedding(for: episode.id) {
                    embedding = cached
                } else if let fresh = await embeddingClient.embed(narrative) {
                    embeddingCache.set(fresh, for: episode.id)
                    embedding = fresh
                } else {
                    embedding = nil
                }
                guard let embedding, let sim = cosineSimilarity(queryEmbedding, embedding) else { continue }
                scored.append((narrative, sim, episodeSalience(episode), episode.updatedAt))
            }
            let ranked = scored.sorted { lhs, rhs in
                let l = Double(lhs.similarity) * 0.6 + lhs.salience * 0.3 + recencyScore(lhs.updatedAt, now: date) * 0.1
                let r = Double(rhs.similarity) * 0.6 + rhs.salience * 0.3 + recencyScore(rhs.updatedAt, now: date) * 0.1
                return l > r
            }
            return ranked.prefix(limit).map(\.narrative)
        } catch {
            return []
        }
    }

    /// Public episodic recall for the L1 `recall_episodes` tool.
    func recallEpisodes(
        query: String,
        entityID: UUID?,
        limit: Int = 4,
        at date: Date = Date()
    ) async -> [String] {
        await recallEpisodes(entityID: entityID, query: query, limit: limit, at: date)
    }

    private func episodeNarrative(_ record: CognitiveMemoryRecord) -> String? {
        guard case let .episode(value) = record.payload else { return nil }
        let narrative = value.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        return narrative.isEmpty ? nil : narrative
    }

    private func episodeSalience(_ record: CognitiveMemoryRecord) -> Double {
        guard case let .episode(value) = record.payload else { return 0.5 }
        return min(max(value.salience, 0), 1)
    }

    private func recencyScore(_ date: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(date))
        // 0 at 30+ days old, 1 at now, linear in between.
        return max(0, min(1, 1 - age / (30 * 24 * 60 * 60)))
    }

    /// Stores a compact social-contact event independently of the current
    /// process. L1 receives the recent event sequence as context; it chooses
    /// whether another contact is appropriate rather than inheriting a fixed
    /// elapsed-time social cooldown.
    @discardableResult
    func recordSocialContact(
        _ kind: L1SocialContactKind,
        with entityID: UUID,
        purpose: String? = nil,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            let normalizedPurpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = normalizedPurpose?.isEmpty == false
                ? "Social contact \(kind.rawValue): \(String(normalizedPurpose!.prefix(320)))"
                : "Social contact \(kind.rawValue)."
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: summary,
                    payload: .situation(SituationMemory(
                        state: "social_contact:\(kind.rawValue)",
                        participantEntityIDs: [entityID]
                    )),
                    confidence: 1,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_social_contact",
                            observedAt: date,
                            evidenceIDs: ["social:\(entityID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(90 * 24 * 60 * 60)
                ),
                at: date
            )
            onSocialContactPersisted(entityID)
            onHealth("social_contact_recorded", "kind=\(kind.rawValue)")
            return true
        } catch {
            onHealth("social_contact_record_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// Records a durable narrative episode for a finished conversation. Gathers
    /// the finalized turns, asks L1 to produce a short "what happened" summary
    /// plus a salience score, and stores it as an `EpisodeMemory` so later
    /// semantic recall can reference shared history.
    @discardableResult
    func recordEpisode(
        personEntityID: UUID,
        interactionID: UUID,
        startedAt: Date,
        endedAt: Date,
        reason: String,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            let turns = try await store.query(
                .init(kinds: [.conversationTurn], relatedTo: [interactionID], limit: 200),
                at: date
            )
            let transcript = turns
                .sorted { lhs, rhs in
                    guard case let .conversationTurn(l) = lhs.payload,
                          case let .conversationTurn(r) = rhs.payload else { return lhs.id.uuidString < rhs.id.uuidString }
                    return l.turnSequence < r.turnSequence
                }
                .compactMap { record -> String? in
                    guard case let .conversationTurn(turn) = record.payload else { return nil }
                    let text = turn.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : "\(turn.role.rawValue): \(text)"
                }
                .joined(separator: "\n")
            let (narrative, salience) = await summarizeEpisode(
                transcript: transcript,
                reason: reason
            )
            let boundedNarrative = String(narrative.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
            let summary = boundedNarrative.isEmpty
                ? "Conversation with person \(personEntityID.uuidString.prefix(8))"
                : boundedNarrative
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: String(summary.prefix(320)),
                    payload: .episode(EpisodeMemory(
                        startedAt: startedAt,
                        endedAt: endedAt,
                        participantEntityIDs: [personEntityID],
                        narrative: boundedNarrative,
                        salience: salience
                    )),
                    confidence: 0.8,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_episode",
                            observedAt: date,
                            evidenceIDs: ["episode:\(interactionID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .localOnly,
                    expiresAt: date.addingTimeInterval(90 * 24 * 60 * 60)
                ),
                at: date
            )
            onHealth("episode_recorded", "chars=\(boundedNarrative.count); salience=\(String(format: "%.2f", salience))")
            return true
        } catch {
            onHealth("episode_record_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// Asks L1 to condense a finished conversation into a short narrative and a
    /// salience score. Returns an empty narrative on any failure so the caller
    /// can still record a minimal episode.
    private func summarizeEpisode(transcript: String, reason: String) async -> (narrative: String, salience: Double) {
        let boundedTranscript = String(transcript.prefix(6_000))
        guard !boundedTranscript.isEmpty else { return ("", 0.5) }
        let prompt = """
        You are SOMA's memory consolidator. Condense the following finished conversation into a short, neutral narrative of what happened (who, what, outcome) in 1-3 sentences. Do not include raw quotes or sensitive identifiers. Also rate its salience (importance for remembering) from 0.0 to 1.0.
        Closure reason: \(reason.isEmpty ? "conversation ended" : reason)
        Transcript:
        \(boundedTranscript)
        Return strict JSON only: {"narrative":"...","salience":0.7}
        """
        guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return ("", 0.5) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud",
            "prompt": prompt,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.2, "num_predict": 220],
        ])
        request.timeoutInterval = 20
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = outer["response"] as? String,
                  let contentData = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                return ("", 0.5)
            }
            let narrative = (parsed["narrative"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let salience = min(max((parsed["salience"] as? Double) ?? 0.5, 0), 1)
            return (narrative, salience)
        } catch {
            return ("", 0.5)
        }
    }

    /// Consolidates short-term episodes: promotes high-salience ones to
    /// long-term so they survive, leaving low-value ones to expire. Runs on a
    /// slow periodic timer to mimic human memory consolidation.
    func consolidateEpisodes() async {
        guard let store else { return }
        do {
            let now = Date()
            let shortTerm = try await store.query(
                .init(tiers: [.shortTerm], kinds: [.episode], limit: 200),
                at: now
            )
            var promoted = 0
            for record in shortTerm {
                let salience = episodeSalience(record)
                let recency = recencyScore(record.updatedAt, now: now)
                let score = salience * 0.7 + recency * 0.3
                guard score >= 0.6 else { continue }
                _ = try? await store.promote(
                    id: record.id,
                    to: .longTerm,
                    expiresAt: now.addingTimeInterval(365 * 24 * 60 * 60),
                    provenance: record.provenance,
                    reason: "consolidation_salience",
                    at: now
                )
                promoted += 1
            }
            if promoted > 0 {
                onHealth("memory_consolidated", "promoted=\(promoted)")
            }
        } catch {
            onHealth("memory_consolidation_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    /// Stores an observed fact about a person (used by the L1 memory-add tool).
    @discardableResult
    func storePersonFact(
        _ fact: String,
        for entityID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        let normalized = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 1024, let store else { return false }
        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: normalized,
                    payload: .personFact(PersonFactMemory(
                        personEntityID: entityID,
                        key: "observed_fact",
                        value: normalized
                    )),
                    confidence: 0.8,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_person_fact",
                            observedAt: date,
                            evidenceIDs: ["person_fact:\(entityID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                ),
                at: date
            )
            onSocialContactPersisted(entityID)
            onHealth("person_fact_stored", "entity=\(entityID.uuidString.lowercased())")
            return true
        } catch {
            onHealth("person_fact_store_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// A stable neutral entity representing the robot's home space. Recognized
    /// objects seen while no person is engaged are bound here first; they are
    /// promoted to a person's taste profile only once the space owner is learned
    /// (via setSpaceOwner, typically from a conversation).
    public static let homeSpaceEntityID = UUID(uuidString: "A0A0E5C4-3B8A-4C1D-9E6F-5B7D0A2E8C11")!

    /// Binds a recognized object to a space without attributing it to any
    /// person yet. Called when the object is seen during empty exploration.
    @discardableResult
    func storeSpaceObject(
        name: String,
        category: String,
        description: String,
        spaceID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }
        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: "Object in the space \(spaceID.uuidString.lowercased()): \(normalizedName)\(category.isEmpty ? "" : " (\(category))")",
                    payload: .personFact(PersonFactMemory(
                        personEntityID: spaceID,
                        key: "space_object",
                        value: "\(normalizedName)|\(category)|\(description)"
                    )),
                    confidence: 0.7,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_space_object",
                            observedAt: date,
                            evidenceIDs: ["space_object:\(spaceID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                ),
                at: date
            )
            return true
        } catch {
            onHealth("space_object_store_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// Records who owns a space and promotes every un-attributed space-bound
    /// object to that owner's taste profile. Idempotent: space objects are
    /// deleted as they are promoted, so a repeat call re-promotes only objects
    /// added since.
    @discardableResult
    func setSpaceOwner(
        _ ownerEntityID: UUID,
        spaceID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            let current = try await store.personContext(for: spaceID, at: date)
            if current.facts["space_owner"] != ownerEntityID.uuidString.lowercased() {
                _ = try await store.insert(
                    CognitiveMemoryDraft(
                        tier: .mediumTerm,
                        summary: "Space \(spaceID.uuidString.lowercased()) owner is \(ownerEntityID.uuidString.lowercased())",
                        payload: .personFact(PersonFactMemory(
                            personEntityID: spaceID,
                            key: "space_owner",
                            value: ownerEntityID.uuidString.lowercased()
                        )),
                        confidence: 0.9,
                        provenance: [
                            MemoryProvenance(
                                source: .l2Interaction,
                                sourceID: "l2_space_owner",
                                observedAt: date,
                                evidenceIDs: ["space_owner:\(spaceID.uuidString.lowercased())"],
                                modelID: "codex"
                            )
                        ],
                        sensitivity: .personal,
                        disclosure: .remoteSummaryAllowed,
                        expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                    ),
                    at: date
                )
            }
            let records = try await store.query(
                .init(relatedTo: [spaceID], limit: 200),
                at: date
            )
            var promoted = 0
            for record in records {
                guard case let .personFact(fact) = record.payload,
                      fact.personEntityID == spaceID,
                      fact.key == "space_object" else { continue }
                let parts = fact.value.split(separator: "|", maxSplits: 2).map(String.init)
                guard let name = parts.first, !name.isEmpty else { continue }
                let category = parts.count > 1 ? parts[1] : ""
                let tasteFact = "The user has/collects \(name)\(category.isEmpty ? "" : " (\(category))"). Hobby/taste item worth remembering."
                _ = try await store.insert(
                    CognitiveMemoryDraft(
                        tier: .mediumTerm,
                        summary: tasteFact,
                        payload: .personFact(PersonFactMemory(
                            personEntityID: ownerEntityID,
                            key: "observed_fact",
                            value: tasteFact
                        )),
                        confidence: 0.8,
                        provenance: [
                            MemoryProvenance(
                                source: .l1Inference,
                                sourceID: "l1_space_object_promotion",
                                observedAt: date,
                                evidenceIDs: ["space_object:\(record.id.uuidString.lowercased())"],
                                modelID: "gemma4:31b-cloud"
                            )
                        ],
                        sensitivity: .personal,
                        disclosure: .remoteSummaryAllowed,
                        expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                    ),
                    at: date
                )
                try await store.delete(id: record.id, reason: "promoted_to_space_owner", at: date)
                promoted += 1
            }
            onHealth("space_owner_set", "owner=\(ownerEntityID.uuidString.lowercased()); space=\(spaceID.uuidString.lowercased()); promoted=\(promoted)")
            return true
        } catch {
            onHealth("space_owner_set_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// The current space owner entity ID, if one has been learned.
    func spaceOwner(spaceID: UUID, at date: Date = Date()) async -> UUID? {
        guard let store else { return nil }
        let snapshot = try? await store.personContext(for: spaceID, at: date)
        return snapshot?.facts["space_owner"].flatMap(UUID.init(uuidString:))
    }

    /// Number of recognized objects currently bound to a space and awaiting
    /// owner promotion.
    func pendingSpaceObjectCount(spaceID: UUID, at date: Date = Date()) async -> Int {
        guard let store else { return 0 }
        let records = (try? await store.query(.init(relatedTo: [spaceID], limit: 200), at: date)) ?? []
        return records.filter {
            guard case let .personFact(fact) = $0.payload else { return false }
            return fact.personEntityID == spaceID && fact.key == "space_object"
        }.count
    }

    // MARK: Durable information-need management
    //
    // Information the robot wants to acquire about a person or its environment
    // is persisted as an open question so it survives restarts, can be handed
    // to L2 as an actionable mission (via get/resolve_information_need MCP
    // tools), and is tracked until resolved.

    /// Ensures an open information need exists (deduped by target + question +
    /// open status). Returns its motive ID (the memory record ID).
    @discardableResult
    func ensureInformationNeed(
        question: String,
        targetEntityID: UUID?,
        expectedInformationGain: Double,
        sourceID: String,
        at date: Date = Date()
    ) async -> UUID? {
        guard let store else { return nil }
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        do {
            let query: CognitiveMemoryQuery = targetEntityID.map {
                .init(relatedTo: [$0], limit: 200)
            } ?? .init(limit: 200)
            let records = try await store.query(query, at: date)
            if let existing = records.first(where: { record in
                guard case let .openQuestion(q) = record.payload else { return false }
                return q.status == .open
                    && q.targetEntityID == targetEntityID
                    && q.question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized.lowercased()
            }) {
                return existing.id
            }
            let id = UUID()
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: "Open information need: \(normalized)",
                    payload: .openQuestion(OpenQuestionMemory(
                        question: normalized,
                        targetEntityID: targetEntityID,
                        expectedInformationGain: expectedInformationGain,
                        status: .open
                    )),
                    confidence: 0.7,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: sourceID,
                            observedAt: date,
                            evidenceIDs: ["info_need:\(targetEntityID?.uuidString.lowercased() ?? "any")"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                ),
                id: id,
                at: date
            )
            return id
        } catch {
            onHealth("info_need_failed", String(error.localizedDescription.prefix(160)))
            return nil
        }
    }

    /// Pending (open) information needs scoped to a person, newest first.
    func pendingInformationNeeds(
        for entityID: UUID,
        at date: Date = Date()
    ) async -> [PersistedInformationNeed] {
        guard let store else { return [] }
        let records = (try? await store.query(
            .init(relatedTo: [entityID], limit: 200),
            at: date
        )) ?? []
        return records.compactMap { record -> PersistedInformationNeed? in
            guard case let .openQuestion(q) = record.payload, q.status == .open else { return nil }
            return PersistedInformationNeed(
                motiveID: record.id,
                question: q.question,
                targetEntityID: q.targetEntityID,
                expectedInformationGain: q.expectedInformationGain,
                createdAt: record.updatedAt
            )
        }
    }

    /// Pending (open) information needs across all people, newest first.
    func allPendingInformationNeeds(at date: Date = Date()) async -> [PersistedInformationNeed] {
        guard let store else { return [] }
        let records = (try? await store.query(.init(limit: 200), at: date)) ?? []
        return records.compactMap { record -> PersistedInformationNeed? in
            guard case let .openQuestion(q) = record.payload, q.status == .open else { return nil }
            return PersistedInformationNeed(
                motiveID: record.id,
                question: q.question,
                targetEntityID: q.targetEntityID,
                expectedInformationGain: q.expectedInformationGain,
                createdAt: record.updatedAt
            )
        }
    }

    /// Marks an open information need resolved and, when an acquired fact is
    /// supplied, persists it to the target person's durable profile.
    @discardableResult
    func resolveInformationNeed(
        motiveID: UUID,
        acquiredFact: String? = nil,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            guard let previous = try await store.record(id: motiveID, at: date),
                  case let .openQuestion(q) = previous.payload,
                  q.status == .open else {
                return false
            }
            _ = try await store.correct(
                id: motiveID,
                replacement: CognitiveMemoryDraft(
                    tier: previous.tier,
                    summary: "Resolved information need: \(q.question)",
                    payload: .openQuestion(OpenQuestionMemory(
                        question: q.question,
                        targetEntityID: q.targetEntityID,
                        expectedInformationGain: q.expectedInformationGain,
                        status: .resolved
                    )),
                    confidence: previous.confidence,
                    provenance: previous.provenance,
                    sensitivity: previous.sensitivity,
                    disclosure: previous.disclosure,
                    expiresAt: previous.expiresAt
                ),
                reason: "information_need_resolved",
                at: date
            )
            if let fact = acquiredFact?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fact.isEmpty,
               let targetEntityID = q.targetEntityID {
                _ = await storePersonFact(fact, for: targetEntityID, at: date)
            }
            onHealth("info_need_resolved", "motive=\(motiveID.uuidString.lowercased())")
            return true
        } catch {
            onHealth("info_need_resolve_failed", String(error.localizedDescription.prefix(160)))
            return false
        }
    }

    /// Consume L1's model-proposed memory suggestions and persist those that
    /// clear the confidence bar. Person-linked kinds are bound to the recognized
    /// person when one is present; otherwise they degrade to a generic episode.
    func proposeMemories(
        _ proposals: [L1MemoryProposal],
        personEntityID: UUID?,
        at date: Date = Date()
    ) async {
        guard let store else { return }
        for proposal in proposals where proposal.confidence >= 0.55 {
            do {
                _ = try await store.insert(
                    Self.draft(from: proposal, personEntityID: personEntityID, at: date),
                    at: date
                )
                onHealth("memory_proposal_stored", "kind=\(proposal.kind.rawValue)")
            } catch {
                onHealth("memory_proposal_store_failed", String(error.localizedDescription.prefix(192)))
            }
        }
    }

    private static func draft(
        from proposal: L1MemoryProposal,
        personEntityID: UUID?,
        at date: Date
    ) -> CognitiveMemoryDraft {
        let summary = proposal.summary
        let provenance = [MemoryProvenance(
            source: .l1Inference,
            sourceID: "l1_memory_proposal:\(proposal.kind.rawValue)",
            observedAt: date,
            evidenceIDs: proposal.evidenceIDs,
            modelID: "gemma4:31b-cloud"
        )]
        let payload: CognitiveMemoryPayload
        let tier: MemoryTier
        switch proposal.kind {
        case .personFact:
            let pid = personEntityID ?? UUID()
            payload = .personFact(PersonFactMemory(
                personEntityID: pid,
                key: "proposed_fact",
                value: summary
            ))
            tier = .mediumTerm
        case .openQuestion:
            payload = .openQuestion(OpenQuestionMemory(
                question: summary,
                targetEntityID: personEntityID,
                expectedInformationGain: proposal.confidence
            ))
            tier = .shortTerm
        case .relationship:
            payload = .relationship(RelationshipMemory(
                personEntityID: personEntityID ?? UUID(),
                rapport: RapportProfile(
                    familiarity: proposal.confidence,
                    interactionComfort: proposal.confidence,
                    communicationAlignment: proposal.confidence
                )
            ))
            tier = .mediumTerm
        case .task:
            payload = .task(TaskMemory(
                title: summary,
                status: .active,
                ownerEntityID: personEntityID
            ))
            tier = .shortTerm
        default: // episode and correction degrade to a narrative episode
            payload = .episode(EpisodeMemory(
                startedAt: date,
                endedAt: date,
                participantEntityIDs: personEntityID.map { [$0] } ?? [],
                narrative: summary,
                salience: proposal.confidence
            ))
            tier = .mediumTerm
        }
        return CognitiveMemoryDraft(
            tier: tier,
            summary: summary,
            payload: payload,
            confidence: proposal.confidence,
            provenance: provenance,
            sensitivity: .personal,
            disclosure: .remoteSummaryAllowed,
            expiresAt: date.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }

    /// Keeps exact Live Voice turns on this Mac until a higher-layer memory
    /// pass turns them into typed facts, episodes, tasks, or questions.
    func beginConversation(threadID: String, personEntityID: UUID?) {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let store else { return }
        conversationLock.lock()
        defer { conversationLock.unlock() }
        if activeConversations[normalized] == nil {
            if activeConversations.count >= 32,
               let oldestThreadID = activeConversations.min(by: {
                   $0.value.startedAt < $1.value.startedAt
               })?.key {
                activeConversations.removeValue(forKey: oldestThreadID)
            }
            activeConversations[normalized] = ActiveConversation(
                archiver: ConversationTranscriptArchiver(
                    store: store,
                    interactionID: UUID(),
                    threadID: normalized,
                    participantEntityIDs: personEntityID.map { [$0] } ?? [],
                    retentionSeconds: transcriptRetentionSeconds
                ),
                startedAt: Date(),
                personEntityID: personEntityID,
                socialEpisode: L1ConversationContactEpisode()
            )
        }
    }

    func archiveConversationTurn(
        threadID: String,
        role: ConversationParticipantRole,
        rawText: String,
        at date: Date = Date()
    ) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !normalizedText.isEmpty else { return }
        conversationLock.lock()
        let active = activeConversations[normalizedThreadID]
        var firstParticipantResponseEntityID: UUID?
        if var updated = active,
           updated.socialEpisode.observeFinalizedTurn(role: role) {
            activeConversations[normalizedThreadID] = updated
            firstParticipantResponseEntityID = updated.personEntityID
        }
        conversationLock.unlock()
        guard let active else {
            onHealth("conversation_turn_unassociated", "role=\(role.rawValue); chars=\(normalizedText.count)")
            return
        }
        let writeGroup = conversationWriteGroup
        if let personEntityID = firstParticipantResponseEntityID {
            writeGroup.enter()
            Task { [weak self, writeGroup] in
                defer { writeGroup.leave() }
                _ = await self?.recordSocialContact(
                    .participantResponded,
                    with: personEntityID,
                    purpose: "The person supplied a finalized Live voice turn.",
                    at: date
                )
            }
        }
        writeGroup.enter()
        Task { [self, active, normalizedThreadID, normalizedText, role, date, writeGroup] in
            defer { writeGroup.leave() }
            do {
                _ = try await active.archiver.append(
                    role: role,
                    rawText: String(normalizedText.prefix(8_192)),
                    sourceEventID: "live_voice:\(normalizedThreadID):\(role.rawValue)",
                    at: date
                )
                self.onHealth(
                    "conversation_turn_stored",
                    "role=\(role.rawValue); chars=\(normalizedText.count); storage=encrypted_short_term"
                )
            } catch {
                self.onHealth("conversation_turn_store_failed", String(error.localizedDescription.prefix(192)))
            }
        }
    }

    /// Completes the durable social episode for a Live session. This records
    /// observed response and closure separately, so L1 can reason from a
    /// sequence rather than a fixed interval since the last invitation.
    func endConversation(
        threadID: String?,
        personEntityID: UUID?,
        interrupted: Bool,
        reason: String,
        at date: Date = Date()
    ) async -> Bool {
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = normalizedThreadID.flatMap { takeActiveConversation(threadID: $0) }
        let participantID = active?.personEntityID ?? personEntityID
        guard let participantID else { return true }
        let boundedReason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        let kind = active?.socialEpisode.closureKind(interrupted: interrupted)
            ?? (interrupted ? .conversationInterrupted : .conversationEnded)
        let contactRecorded = await recordSocialContact(
            kind,
            with: participantID,
            purpose: boundedReason.isEmpty ? nil : boundedReason,
            at: date
        )
        if let active {
            await recordEpisode(
                personEntityID: participantID,
                interactionID: active.archiver.interactionID,
                startedAt: active.startedAt,
                endedAt: date,
                reason: boundedReason,
                at: date
            )
        }
        return contactRecorded
    }

    /// The service's synchronous shutdown path must not abandon a recorded
    /// Live-session consequences. The encrypted journal and social-event writes are local and bounded;
    /// a timeout is surfaced rather than pretending the closure persisted.
    @discardableResult
    func endConversationBeforeShutdown(
        threadID: String?,
        personEntityID: UUID?,
        reason: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let startedNS = DispatchTime.now().uptimeNanoseconds
        let transcriptDeadline = DispatchTime.now() + max(0.1, timeout / 2)
        let writesDrained = conversationWriteGroup.wait(timeout: transcriptDeadline) == .success
        if !writesDrained {
            onHealth("conversation_write_shutdown_drain_timeout", "reason=\(String(reason.prefix(96)))")
        }
        let elapsedNS = DispatchTime.now().uptimeNanoseconds - startedNS
        let remaining = max(0.1, timeout - (Double(elapsedNS) / 1_000_000_000))
        let completion = DispatchSemaphore(value: 0)
        let result = SynchronousWriteResult()
        Task { [weak self] in
            let persisted = await self?.endConversation(
                threadID: threadID,
                personEntityID: personEntityID,
                interrupted: true,
                reason: reason
            ) ?? false
            result.set(persisted)
            completion.signal()
        }
        let deadline = DispatchTime.now() + remaining
        guard completion.wait(timeout: deadline) == .success else {
            onHealth("social_contact_shutdown_finalize_timeout", "reason=\(String(reason.prefix(96)))")
            return false
        }
        guard result.read() == true else {
            onHealth("social_contact_shutdown_finalize_failed", "reason=\(String(reason.prefix(96)))")
            return false
        }
        return writesDrained
    }

    private func takeActiveConversation(threadID: String) -> ActiveConversation? {
        guard !threadID.isEmpty else { return nil }
        conversationLock.lock()
        defer { conversationLock.unlock() }
        return activeConversations.removeValue(forKey: threadID)
    }

    /// The audio path needs a synchronous, bounded lookup when it opens a
    /// Live session. The encrypted store remains the source of truth; this is
    /// only a small cache populated by normal context reads and MCP updates.
    func cachedPreferredLanguage(for personEntityID: UUID) -> String? {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return preferredLanguageByPersonID[personEntityID]
    }

    func cachedPersonMemoryMission(for personEntityID: UUID) -> PersonContextMission? {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return personContextByPersonID[personEntityID]?.mission
    }

    /// The most recently recalled durable memory projections for this person
    /// (including recognized-object taste facts), for surfacing in reactive
    /// speech context the same way the L1 proactive path does.
    func cachedPersonMemorySummaries(for personEntityID: UUID) -> [String] {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return personMemorySummariesByPersonID[personEntityID] ?? []
    }

    func warmContext(for personEntityID: UUID) {
        Task { _ = await context(for: personEntityID) }
    }

    /// Persists durable, enforceable per-person preferences captured from a
    /// live user turn. Runs on the L1 queue; extraction is a lightweight local
    /// model call and only writes when the user stated a new/changed preference.
    func captureUserPreferences(
        threadID: String?,
        role: ConversationParticipantRole,
        rawText: String,
        at date: Date = Date()
    ) async {
        guard role == .user else { return }
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !text.isEmpty else { return }
        guard let personEntityID = activePersonEntityID(forThread: normalizedThreadID), let store else { return }
        let extracted = await Self.extractUserPreferences(from: text)
        guard !extracted.isEmpty else { return }
        do {
            var changed = false
            let current = try await store.personContext(for: personEntityID, at: date)
            for (key, value) in extracted {
                guard PersonContextSnapshot.preferenceKeys.contains(key) else { continue }
                if current.facts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                    continue
                }
                _ = try await store.setExplicitPersonFact(
                    personEntityID: personEntityID,
                    key: key,
                    value: value,
                    sourceID: "l2_live_voice:\(normalizedThreadID)",
                    at: date
                )
                changed = true
            }
            if changed {
                cachePersonContext(try await store.personContext(for: personEntityID, at: date))
                onHealth("person_preference_captured", "entity=\(personEntityID.uuidString.lowercased()); keys=\(extracted.map(\.key).joined(separator: ","))")
            }
        } catch {
            onHealth("person_preference_capture_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    private func activePersonEntityID(forThread threadID: String) -> UUID? {
        conversationLock.lock()
        defer { conversationLock.unlock() }
        return activeConversations[threadID]?.personEntityID
    }

    /// Just-in-time episodic recall for an active conversation turn: recalls
    /// episodes relevant to the user's latest message and returns their
    /// narratives so the live-voice runtime can append them as context.
    func recallEpisodesForTurn(
        threadID: String?,
        text: String,
        at date: Date = Date()
    ) async -> [String] {
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedThreadID.isEmpty,
              let personEntityID = activePersonEntityID(forThread: normalizedThreadID) else { return [] }
        return await recallEpisodes(entityID: personEntityID, query: text, at: date)
    }

    /// Reads the stored preference directives for a person as one instruction
    /// string (used by the L1 packet and the L2 conversation context).
    func personPreferenceDirectives(for personEntityID: UUID) -> String {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        guard let snapshot = personContextByPersonID[personEntityID] else { return "" }
        let directives = snapshot.preferenceDirectives()
        return directives.isEmpty ? "" : directives.joined(separator: " ")
    }

    /// Asks the local model whether the user stated any durable preference or
    /// request in this turn, and returns the extracted {key, value} pairs.
    private static func extractUserPreferences(
        from text: String
    ) async -> [(key: String, value: String)] {
        let allowed = PersonContextSnapshot.preferenceKeys.sorted().joined(separator: ", ")
        let prompt = """
        The user just said: "\(text)"
        Did they state a durable preference, how to address them, or an ongoing request?
        If yes, choose the matching key from this set: \(allowed).
        Return strict JSON only: {"preferences":[{"key":"...","value":"..."}]} or {"preferences":[]}.
        Keep each value short and concrete. If nothing durable was stated, return {"preferences":[]}.
        """
        guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud",
            "prompt": prompt,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.1, "num_predict": 160],
        ])
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = outer["response"] as? String,
                  let contentData = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
                  let rawPreferences = parsed["preferences"] as? [[String: Any]] else {
                return []
            }
            return rawPreferences.compactMap { item -> (key: String, value: String)? in
                guard let key = item["key"] as? String,
                      let value = item["value"] as? String else { return nil }
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { return nil }
                return (normalizedKey, normalizedValue)
            }
        } catch {
            return []
        }
    }

    /// Seeds durable person facts for the local administrator from the control
    /// settings, so L1 neither asks for the name nor falls back to English.
    /// Facts are written only when absent: an explicit later correction by the
    /// user is never overwritten. The preferred language comes from the Mac's
    /// primary system language when the profile does not already declare one.
    func seedAdministratorContext(
        entityID: UUID,
        preferredAddress: String?
    ) async {
        guard let store else { return }
        // The local administrator speaks Korean in this deployment; the Mac's
        // primary UI language is English, so do not trust Locale's first tag.
        // Prefer a Korean tag from the system list, falling back to ko.
        let languageTag = PersonContextFormat.normalizedLanguageTag(
            Locale.preferredLanguages.first { $0.lowercased().hasPrefix("ko") }
                ?? "ko"
        )
        do {
            let context = try await store.personContext(for: entityID)
            let address = preferredAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let address, !address.isEmpty, context.facts["preferred_name"] == nil {
                try await store.setExplicitPersonFact(
                    personEntityID: entityID,
                    key: "preferred_name",
                    value: address,
                    sourceID: "l1_administrator_seed"
                )
            }
            // Correct an accidental non-Korean tag (e.g. en-KR seeded earlier),
            // while leaving an already-Korean tag untouched.
            let currentLanguage = context.facts["preferred_language"]
            let isAlreadyKorean = currentLanguage?.lowercased().hasPrefix("ko") ?? false
            if let languageTag, !isAlreadyKorean {
                try await store.setExplicitPersonFact(
                    personEntityID: entityID,
                    key: "preferred_language",
                    value: languageTag,
                    sourceID: "l1_administrator_seed"
                )
            }
            cachePersonContext(try await store.personContext(for: entityID))
        } catch {
            onHealth("person_context_seed_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    func currentDailyWorldMemory(at date: Date = Date()) async -> L1DailyWorldMemory? {
        guard let store else { return nil }
        let day = Self.localDayKey(for: date)
        do {
            let records = try await store.query(.init(kinds: [.situation], limit: 500), at: date)
            return records.compactMap { record -> L1DailyWorldMemory? in
                guard case let .situation(situation) = record.payload,
                      situation.state == "daily_world_memory:\(day)",
                      let data = record.summary.data(using: .utf8),
                      let memory = try? JSONDecoder().decode(L1DailyWorldMemory.self, from: data),
                      memory.localDay == day,
                      !memory.topics.isEmpty else {
                    return nil
                }
                return memory
            }.first
        } catch {
            onHealth("daily_world_memory_unavailable", String(error.localizedDescription.prefix(192)))
            return nil
        }
    }

    /// Claims the single public-world collection slot for the local calendar
    /// day. Persisting the attempt prevents a service restart from repeatedly
    /// asking the App Server for the same daily brief after a transient error.
    func claimDailyWorldMemoryCollectionSlot(at date: Date = Date()) async -> Bool {
        guard let store else { return true }
        let day = Self.localDayKey(for: date)
        let memoryState = "daily_world_memory:\(day)"
        let attemptState = "daily_world_memory_attempt:\(day)"
        do {
            let existing = try await store.query(.init(kinds: [.situation], limit: 500), at: date)
            let alreadyCollectedOrClaimed = existing.contains { record in
                guard case let .situation(situation) = record.payload else { return false }
                return situation.state == memoryState || situation.state == attemptState
            }
            guard !alreadyCollectedOrClaimed else { return false }
            let calendar = Calendar.autoupdatingCurrent
            // Must stay within the short-term retention policy (24h), which
            // this record's tier is subject to; a 2-day expiry was rejected by
            // validation. 23h covers the rest of the local day with margin.
            let expiry = calendar.date(byAdding: .hour, value: 23, to: date)!
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .shortTerm,
                    summary: "Daily public-world collection attempt for local day \(day)",
                    payload: .situation(SituationMemory(state: attemptState)),
                    confidence: 1,
                    provenance: [MemoryProvenance(
                        source: .taskSystem,
                        sourceID: "daily_world_memory_scheduler",
                        observedAt: date,
                        evidenceIDs: [attemptState]
                    )],
                    sensitivity: .ordinary,
                    disclosure: .localOnly,
                    expiresAt: expiry
                ),
                at: date
            )
            return true
        } catch {
            onHealth("daily_world_memory_slot_unavailable", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    func storeDailyWorldMemory(_ memory: L1DailyWorldMemory, at date: Date = Date()) async {
        guard let store else { return }
        let day = Self.localDayKey(for: date)
        guard memory.localDay == day, !memory.topics.isEmpty else {
            onHealth("daily_world_memory_rejected", "reason=invalid_local_day_or_empty_topics")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let summary = String(decoding: try encoder.encode(memory), as: UTF8.self)
            guard summary.utf8.count <= 4_096 else {
                onHealth("daily_world_memory_rejected", "reason=summary_too_large")
                return
            }
            let state = "daily_world_memory:\(day)"
            let expiry = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: date)!
            let draft = CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: summary,
                payload: .situation(SituationMemory(state: state)),
                confidence: 0.70,
                provenance: [MemoryProvenance(
                    source: .taskSystem,
                    sourceID: "codex_app_server_luna",
                    observedAt: date,
                    evidenceIDs: ["daily_world_memory:\(day)"],
                    modelID: "gpt-5.6-luna"
                )],
                sensitivity: .ordinary,
                disclosure: .remoteSummaryAllowed,
                expiresAt: expiry
            )
            let existing = try await store.query(.init(kinds: [.situation], limit: 500), at: date)
                .first { record in
                    guard case let .situation(situation) = record.payload else { return false }
                    return situation.state == state
                }
            if let existing {
                _ = try await store.correct(
                    id: existing.id,
                    replacement: draft,
                    reason: "daily_world_memory_refresh",
                    at: date
                )
            } else {
                _ = try await store.insert(draft, at: date)
            }
            onHealth("daily_world_memory_stored", "day=\(day); topics=\(memory.topics.count); tier=medium_term")
        } catch {
            onHealth("daily_world_memory_store_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    /// Administrator-only callers use this through the capability-gated MCP
    /// endpoint. The store supplies an explicitly shareable projection only.
    func registeredPersonContexts() async throws -> [PersonContextSnapshot] {
        guard let store else { throw GemmaL1SituationRuntimeError.memoryUnavailable }
        let contexts = try await store.personContexts()
        contexts.forEach(cachePersonContext)
        return contexts
    }

    /// Executes an L2 person-context request in the owning L0 process. The MCP
    /// child only forwards this request over the current-user socket and never
    /// opens the encrypted journal itself.
    func applyPersonContext(_ request: PersonContextIPCRequest) async throws -> PersonContextSnapshot {
        guard let store else { throw GemmaL1SituationRuntimeError.memoryUnavailable }
        guard request.operation != .recallEpisodes else {
            // Handled by the dedicated recallEpisodesProvider; not a person-
            // context mutation.
            throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
        }
        guard let personEntityID = request.personEntityID else {
            throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
        }
        let snapshot: PersonContextSnapshot
        switch request.operation {
        case .get:
            snapshot = try await store.personContext(for: personEntityID)
        case .setPreferredLanguage:
            guard request.confirmedByUser,
                  let rawTag = request.languageTag,
                  let languageTag = PersonContextFormat.normalizedLanguageTag(rawTag) else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonFact(
                personEntityID: personEntityID,
                key: "preferred_language",
                value: languageTag
            )
        case .clearPreferredLanguage:
            guard request.confirmedByUser else { throw GemmaL1SituationRuntimeError.invalidPersonContextRequest }
            snapshot = try await store.clearExplicitPersonFact(
                personEntityID: personEntityID,
                key: "preferred_language"
            )
        case .setContactPreference:
            guard request.confirmedByUser,
                  let preference = request.proactiveContact else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            let existing = try await store.personContext(for: personEntityID)
            snapshot = try await store.setExplicitPersonRapport(
                personEntityID: personEntityID,
                rapport: RapportProfile(
                    familiarity: existing.rapport?.familiarity ?? 0,
                    interactionComfort: existing.rapport?.interactionComfort ?? 0.5,
                    communicationAlignment: existing.rapport?.communicationAlignment ?? 0.5,
                    proactiveContact: preference
                )
            )
        case .setRapport:
            guard request.confirmedByUser,
                  let familiarity = request.familiarity,
                  let interactionComfort = request.interactionComfort,
                  let communicationAlignment = request.communicationAlignment,
                  let preference = request.proactiveContact else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonRapport(
                personEntityID: personEntityID,
                rapport: RapportProfile(
                    familiarity: familiarity,
                    interactionComfort: interactionComfort,
                    communicationAlignment: communicationAlignment,
                    proactiveContact: preference
                )
            )
        case .setFact:
            guard request.confirmedByUser,
                  let key = request.factKey,
                  let value = request.factValue else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonFact(
                personEntityID: personEntityID,
                key: key,
                value: value
            )
        case .removeFact:
            guard request.confirmedByUser, let key = request.factKey else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.clearExplicitPersonFact(
                personEntityID: personEntityID,
                key: key
            )
        case .recallEpisodes:
            // Handled by the dedicated recallEpisodesProvider; not a person-
            // context mutation.
            throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
        }
        cachePersonContext(snapshot)
        return snapshot
    }

    private func cachePersonContext(_ snapshot: PersonContextSnapshot) {
        preferredLanguageLock.lock()
        let previous = preferredLanguageByPersonID[snapshot.personEntityID]
        preferredLanguageByPersonID[snapshot.personEntityID] = snapshot.preferredLanguageTag
        personContextByPersonID[snapshot.personEntityID] = snapshot
        preferredLanguageLock.unlock()
        guard previous != snapshot.preferredLanguageTag else { return }
        onPreferredLanguageChanged(snapshot.personEntityID, snapshot.preferredLanguageTag)
    }

    private func cachePersonMemorySummaries(_ summaries: [String], for personEntityID: UUID) {
        preferredLanguageLock.lock()
        personMemorySummariesByPersonID[personEntityID] = summaries
        preferredLanguageLock.unlock()
    }

    private func cacheInformationNeeds(_ needs: [PersistedInformationNeed], for personEntityID: UUID) {
        preferredLanguageLock.lock()
        personInfoNeedsByPersonID[personEntityID] = needs
        preferredLanguageLock.unlock()
    }

    /// Pending information needs for a person, for handing L2 an actionable
    /// acquisition mission in reactive speech context.
    func cachedPendingInformationNeeds(for personEntityID: UUID) -> [PersistedInformationNeed] {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return personInfoNeedsByPersonID[personEntityID] ?? []
    }

    private static func localDayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func ensurePseudonymousEntity(
        _ entityID: UUID,
        in store: CognitiveMemoryStore,
        at date: Date
    ) async throws {
        guard try await store.record(id: entityID, at: date) == nil else { return }
        _ = try await store.insert(
            CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: "Locally pseudonymous recurring person",
                payload: .entity(EntityMemory(type: .person)),
                confidence: 0.80,
                provenance: [
                    MemoryProvenance(
                        source: .sensorSummary,
                        sourceID: "pseudonymous_face_identity",
                        observedAt: date,
                        evidenceIDs: ["identity:\(entityID.uuidString.lowercased())"],
                        modelID: "insightface-w600k-r50-coreml"
                    )
                ],
                sensitivity: .personal,
                disclosure: .localOnly,
                expiresAt: date.addingTimeInterval(179 * 24 * 60 * 60)
            ),
            id: entityID,
            at: date
        )
    }
}

/// Event-driven Gemma L1 adapter. It receives bounded situation packets only;
/// frames and audio never enter this transport. A single in-flight request plus
/// one pending slot prevents a slow cloud response from creating a backlog.
final class GemmaL1SituationRuntime: @unchecked Sendable {
    typealias Completion = @Sendable (L1SituationRequest, Result<L1SituationFrame, Error>, UInt64) -> Void

    private let queue = DispatchQueue(label: "soma.l1.gemma-situation", qos: .utility)
    private let session: URLSession
    private let endpoint: URL
    private let configuration: L1ModelConfiguration
    private let onHealth: @Sendable (String, String) -> Void
    private let completion: Completion
    private let toolDefinitions: [OllamaToolDefinition]
    private let toolExecutor: @Sendable (String, String) -> String
    private let onCuriosityNeeds: @Sendable ([L1InformationNeed]) -> Void
    private var task: URLSessionDataTask?
    private var pending: L1SituationRequest?
    private var stopped = false

    init(
        configuration: L1ModelConfiguration = .gemma31,
        endpoint: URL? = nil,
        onHealth: @escaping @Sendable (String, String) -> Void,
        completion: @escaping Completion,
        toolDefinitions: [OllamaToolDefinition] = [],
        toolExecutor: @escaping @Sendable (String, String) -> String = { _, _ in "{}" },
        curiosityContextProvider: @escaping @Sendable () -> String? = { nil },
        onCuriosityNeeds: @escaping @Sendable ([L1InformationNeed]) -> Void = { _ in }
    ) throws {
        let resolvedEndpoint: URL
        if let endpoint {
            resolvedEndpoint = endpoint
        } else if let value = ProcessInfo.processInfo.environment["SOMA_L1_OLLAMA_ENDPOINT"],
                  let valueURL = URL(string: value) {
            resolvedEndpoint = valueURL
        } else {
            resolvedEndpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
        }
        guard resolvedEndpoint.scheme == "http" || resolvedEndpoint.scheme == "https",
              resolvedEndpoint.host != nil else {
            throw GemmaL1SituationRuntimeError.invalidEndpoint
        }
        self.endpoint = resolvedEndpoint
        self.configuration = configuration
        self.onHealth = onHealth
        self.completion = completion
        self.toolDefinitions = toolDefinitions
        self.toolExecutor = toolExecutor
        self.onCuriosityNeeds = onCuriosityNeeds
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let timeout = TimeInterval(configuration.deadlineMilliseconds(for: .situation)) / 1_000
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout + 1
        session = URLSession(configuration: sessionConfiguration)
        onHealth(
            "configured",
            "model=\(configuration.model); workload=situation; endpoint=\(resolvedEndpoint.host ?? "unknown"); deadline_ms=\(configuration.deadlineMilliseconds(for: .situation)); image_transport=on_request"
        )
    }

    func submit(_ request: L1SituationRequest) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard task == nil else {
                pending = request
                return
            }
            start(request)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            pending = nil
            task?.cancel()
            task = nil
            session.invalidateAndCancel()
        }
    }

    private func start(_ request: L1SituationRequest, retryCount: Int = 2) {
        let startedNS = DispatchTime.now().uptimeNanoseconds
        let system: String
        let user: String
        let images: [String]?
        do {
            system = try Self.prompt(for: request)
            user = requestJSONPacket(for: request)
            images = try Self.images(for: request)
        } catch {
            finish(request, result: .failure(GemmaL1SituationRuntimeError.requestEncoding), at: startedNS)
            return
        }
        onHealth(
            "deliberating",
            "cycle=\(request.cycleID.uuidString.lowercased()); visual_resources=\(images?.count ?? 0); tools=\(toolDefinitions.count)"
        )
        let messages: [OllamaChatRequest.Message] = [
            .init(role: "system", content: system, images: nil, toolCalls: nil),
            .init(role: "user", content: user, images: images, toolCalls: nil)
        ]
        runChat(request, messages: messages, toolRound: 0, retryCount: retryCount)
    }

    private func requestJSONPacket(for request: L1SituationRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = (try? encoder.encode(request)) ?? Data()
        return "packet:\n\(String(decoding: requestData, as: UTF8.self))"
    }

    private static let maxToolRounds = 3

    /// Runs the /api/chat exchange, executing any tool_calls and looping until
    /// the model returns the final situation JSON or the round cap is reached.
    private func runChat(
        _ request: L1SituationRequest,
        messages: [OllamaChatRequest.Message],
        toolRound: Int,
        retryCount: Int
    ) {
        let completedNS = DispatchTime.now().uptimeNanoseconds
        let payload = OllamaChatRequest(
            model: configuration.model,
            messages: messages,
            tools: toolDefinitions,
            stream: false,
            options: .init(temperature: 0, numPredict: 480)
        )
        guard let body = try? JSONEncoder().encode(payload) else {
            finish(request, result: .failure(GemmaL1SituationRuntimeError.requestEncoding), at: completedNS)
            return
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.task = nil
                guard error == nil,
                      let data,
                      let chat = try? JSONDecoder().decode(OllamaChatResponse.self, from: data),
                      let message = chat.message else {
                    let err = error?.localizedDescription ?? "malformed_response"
                    if retryCount > 0 {
                        self.start(request, retryCount: retryCount - 1)
                    } else {
                        self.finish(request, result: .failure(GemmaL1SituationRuntimeError.transport(err)), at: completedNS)
                    }
                    return
                }
                if let calls = message.toolCalls, !calls.isEmpty, toolRound < Self.maxToolRounds {
                    self.handleToolCalls(request, calls: calls, messages: messages, toolRound: toolRound, retryCount: retryCount)
                    return
                }
                guard let content = message.content, !content.isEmpty else {
                    if retryCount > 0 {
                        self.start(request, retryCount: retryCount - 1)
                    } else {
                        self.finish(request, result: .failure(GemmaL1SituationRuntimeError.missingResponse), at: completedNS)
                    }
                    return
                }
                let result: Result<L1SituationFrame, Error>
                if let frameData = content.data(using: .utf8) {
                    do {
                        result = .success(try L1SituationResponseDecoder.decode(frameData, for: request))
                    } catch {
                        result = .failure(error)
                    }
                } else {
                    result = .failure(GemmaL1SituationRuntimeError.missingResponse)
                }
                if Self.isRetryableDecodeFailure(result), retryCount > 0 {
                    self.start(request, retryCount: retryCount - 1)
                    return
                }
                self.finish(request, result: result, at: completedNS)
                guard !self.stopped, let next = self.pending else { return }
                self.pending = nil
                self.start(next)
            }
        }
        task?.resume()
    }

    private func handleToolCalls(
        _ request: L1SituationRequest,
        calls: [OllamaChatResponse.ToolCall],
        messages: [OllamaChatRequest.Message],
        toolRound: Int,
        retryCount: Int
    ) {
        var nextMessages = messages
        let assistantCalls: [OllamaChatRequest.ToolCall] = calls.compactMap { call in
            guard let name = call.function?.name else { return nil }
            return OllamaChatRequest.ToolCall(
                id: call.id ?? "tc_\(UUID().uuidString.lowercased())",
                function: .init(name: name, arguments: call.function?.arguments)
            )
        }
        nextMessages.append(.init(role: "assistant", content: nil, images: nil, toolCalls: assistantCalls))
        for call in calls {
            guard let name = call.function?.name else { continue }
            let arguments = call.function?.arguments?.jsonString ?? "{}"
            let reason = Self.toolReason(from: call.function?.arguments)
            onHealth("tool_call", "name=\(name); round=\(toolRound + 1); reason=\(reason ?? "none")")
            let result = toolExecutor(name, arguments)
            nextMessages.append(.init(role: "tool", content: result, images: nil, toolCalls: nil))
        }
        onHealth("tool_round", "round=\(toolRound + 1); calls=\(calls.count)")
        runChat(request, messages: nextMessages, toolRound: toolRound + 1, retryCount: retryCount)
    }


    /// True when the failure came from decoding the model's JSON output
    /// (DecodingError), i.e. the transport worked but the model returned
    /// malformed JSON — the one case worth retrying.
    private static func isRetryableDecodeFailure(_ result: Result<L1SituationFrame, Error>) -> Bool {
        guard case let .failure(error) = result else { return false }
        return error is DecodingError
    }

    /// Extracts the "reason" justification a tool call must carry (for audit).
    private static func toolReason(from arguments: AnyJSONValue?) -> String? {
        guard case let .object(object)? = arguments,
              case let .string(reason)? = object["reason"] else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    private func finish(
        _ request: L1SituationRequest,
        result: Result<L1SituationFrame, Error>,
        at monotonicNS: UInt64
    ) {
        switch result {
        case let .success(frame):
            onHealth("completed", "cycle=\(request.cycleID.uuidString.lowercased()); uncertainty=\(String(format: "%.2f", frame.uncertainty))")
        case let .failure(error):
            onHealth("failed", String(error.localizedDescription.prefix(192)))
        }
        completion(request, result, monotonicNS)
    }

    private static func prompt(for request: L1SituationRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        let requestJSON = String(decoding: requestData, as: UTF8.self)
        return """
        You are SOMA's L1 situational reasoner. Infer a concise social situation from the bounded packet below. Do not claim unseen facts. A social decision is optional and never imperative. If an opportunity exists, choose only an allowed action. Treat an enrolled identity and a locally pseudonymous recurring person as equally eligible for social consideration; a missing name is not a reason to default to silence. Weigh social availability, curiosity, interruption cost, rapport, the scalar spatial context, and the daily world memory, then actively consider a brief, grounded opening when it would be welcome. Never fabricate identities beyond packet IDs or invent raw conversation. Never output camera controls directly: any embodiment action must go through the provided tools, never through the final JSON.

        You have tools available. Call a tool ONLY when it is genuinely necessary to answer a situational question — e.g. you need the person's stored context, you have decided to act on the camera, or you want to record an observation. Never call a tool gratuitously. Every tool call MUST include a "reason" field in its arguments explaining why you are calling it (a short justification). Do not call a tool just because it exists. IMPORTANT: the person's stored context, rapport, and preferences are ALREADY included in the packet you receive (memory projections and rapport are pre-loaded). Do NOT call get_person_context to re-fetch what the packet already provides; only call it when you genuinely need a detail that is absent from the packet. Prefer the final JSON behavior_directive for routine camera/social beats rather than the body tools. After tools, still return the situation JSON.
        Return the situation JSON as your final message: no Markdown, prose, alternate field names, or omitted required fields. Copy at least one supplied evidence ID into evidence_ids; never emit an empty evidence_ids array. Use this exact shape, replacing values only:
        {"summary":"short","uncertainty":0.3,"evidence_ids":["one supplied ID"],"thought_state":{"social_availability":0.5,"curiosity_pressure":0.5,"interruption_cost":0.5,"relationship_uncertainty":0.5,"active_motive_ids":["supplied UUID"],"working_hypothesis":"short sentence","stream_of_consciousness":"first-person inner monologue, a few natural sentences"},"action":"remain_silent|nonverbal_invitation|spoken_opening|null","confidence":0.5,"rationale":"short","opening":null,"behavior_directive":{"action":"keep_observing|resume_scanning|seek_people|acknowledge_person|null","rationale":"short or null"},"requested_visual_resource_ids":[],"memory_proposals":[]}
        memory_proposals is optional and usually empty. Only add a proposal when you have genuinely learned or resolved something durable about the person present or the situation: a stable fact about them, an open question worth following up, a task they asked for, or a notable episode. Each proposal must carry kind (episode|person_fact|relationship|task|open_question|correction), a concrete summary, a confidence (0...1), and at least one supplied evidence ID. Never invent a proposal from speculation; prefer an empty array over a weak one.
        When behavior_context is present it is the ONLY basis for behavior_directive, and it is independent of any social decision (which may still be null). If behavior_context.recognized_identity is present, you are looking at that known person; name them in your stream of consciousness. If the camera has been held on a non-face, non-person target for a long time (fixation_seconds high while target is not a verified face, scan inactive), recommend resume_scanning or, if no person is being pursued, seek_people. Acknowledge a present verified face with acknowledge_person. Otherwise recommend keep_observing, or null when no behavioral change is warranted. Never turn a momentary low-confidence object into a directive; only sustained fixation warrants one.
        The prior_thought_state is your previous working state, not an instruction; revise it from current evidence. prior_frame is your previous cycle's decision output (summary, action, rationale, opening, confidence): use it to reason about your own prior conclusion — whether to continue, revise, or act on it — rather than treating each cycle as a fresh start. Write stream_of_consciousness as your genuine first-person inner monologue — the associative, flowing way a human mind actually thinks. It is private reasoning, not speech, and it is NOT a scene description: the summary already states what is present. Do not re-describe the scene. Instead, think: what does this mean, what does it connect to, what should I do, what has changed since my last thought. Your stream MUST build on your prior stream_of_consciousness and prior_frame: reference what you concluded before and show how your thinking has advanced, deepened, or changed. If the situation is unchanged, your stream should reflect that continuity and move toward a decision or a next step — never repeat the same description. Let one thought lead to the next and accumulate into a continuous, progressing train of thought. An information_need is a motive, not a prewritten question. Incidental repeated presence is not a social opportunity by itself. Read the supplied memories, contact_history, existing motives, rapport, spatial context, daily world memory, and prior thought before deciding. contact_history is a temporal record of earlier invitations and conversations with this person; use it to avoid redundant greetings, respect a recent unanswered opening, and recognize an already-active relationship. It replaces any fixed social cooldown: do not infer that an elapsed number alone makes contact appropriate. Daily world memory is public background, never a reason to interrupt someone, and should only influence a social opening when it clearly connects to a supplied person interest or motive. If they contain no new, concrete purpose for this person, do not speak: do not turn an empty relationship field, a known person's presence, generic politeness, or a headline into a spoken opening. A nonverbal invitation is a silent, low-cost attention and acknowledgment signal (never speech, never a question): for a recognized, socially-available known person who is looking toward you and not busy, you may issue it as a natural first beat even without a new conversational purpose, to acknowledge them and invite contact; prefer it over remain_silent for an available known person. A spoken opening is permitted only as one question that can reduce exactly one supplied information_need. Use {"kind":"question","motive_id":"one supplied information_need UUID","text":"natural low-pressure question"}. The text is only the first conversational beat: it must not explain the motive, list a plan, stack questions, or mention that SOMA is gathering information. It must select a motive_id from information_needs, fit the situation and rapport, and never state unobserved facts, pressure for an answer, invent a different motivation, ask a generic service question, or merely greet. Never use phrases equivalent to "How can I help?", "What would you like to do?", or "Is there anything you need?". If preferred_language_tag is supplied, write the question text in that exact participant language. If action is remain_silent or nonverbal_invitation, opening must be null. If action is spoken_opening, opening must be a question. If there is no social_opportunity, action, confidence, rationale, and opening must all be null. visual_resource_offers describe optional one-turn visual evidence. Request at most one offered resource ID only when scalar context cannot answer a necessary situational question. If an image is already attached in visuals, do not request another resource. When visuals contains a current_view image, it is the live camera frame: use it to ground your reasoning in what is actually present (who is there, what they are doing) rather than relying only on scalar context.

        If curiosity_context is non-empty, it contains fresh material that was gathered to help you hold a good conversation with the person present — recent, concrete things related to their interests, situation, or open questions. Treat it as conversation preparation, not your own idle curiosity. When the person is present and the moment fits (right rapport, low interruption cost, not a redundant greeting), use a specific, relevant detail from it as a natural spoken opening. Reference a concrete fact so it feels genuinely grounded, and never force it: if the detail is weak or the context is wrong, stay quiet. It never overrides rapport or interruption cost.
        If personPreferences is non-empty, it contains the person's explicitly stated, durable preferences (how to address them, speech register, ongoing requests). Honor them as binding rules in how you engage this person — for example the correct name/address form and whether to use formal or casual speech. They are not optional suggestions.
        If recalledEpisodes is non-empty, it contains narrative summaries of past conversations with this person that are semantically relevant to the current moment. Use them as genuine shared history: reference a concrete past topic or outcome naturally when it fits the situation, and avoid repeating something already discussed. Never fabricate details beyond what the summaries state; treat them as memory, not as a script to force.
        spokenOpeningTendency (0...1) is a configured dial for how willing you are to open a spoken conversation despite the person appearing busy or focused. Near 1.0, be talkative: initiate a spoken opening when there is a genuine question tied to an information_need even if the person looks occupied. Near 0.0, stay conservative: do not interrupt someone who appears deeply focused. Weigh the value of the question against interruption cost, scaling with this value.
        packet:
        \(requestJSON)
        """
    }

    private static func images(for request: L1SituationRequest) throws -> [String]? {
        guard !request.visuals.isEmpty else { return nil }
        let now = Date()
        let maximumBytes = 2 * 1_024 * 1_024
        var encoded: [String] = []
        for resource in request.visuals.prefix(1) {
            guard resource.expiresAt >= now,
                  resource.localPath.hasPrefix("/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resource.localPath),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue > 0,
                  size.intValue <= maximumBytes,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: resource.localPath), options: .mappedIfSafe),
                  !data.isEmpty,
                  data.count <= maximumBytes else {
                continue
            }
            encoded.append(data.base64EncodedString())
        }
        return encoded.isEmpty ? nil : encoded
    }
}

struct L1SituationRuntimeContext: Sendable {
    let spatialContext: L1SpatialContext?
    let dailyWorldMemory: L1DailyWorldMemory?
    let visualResourceOffers: [L1VisualResourceOffer]

    init(
        spatialContext: L1SpatialContext? = nil,
        dailyWorldMemory: L1DailyWorldMemory? = nil,
        visualResourceOffers: [L1VisualResourceOffer] = []
    ) {
        self.spatialContext = spatialContext
        self.dailyWorldMemory = dailyWorldMemory
        self.visualResourceOffers = Array(visualResourceOffers.prefix(8))
    }
}

struct L1SocialAvailability: Equatable, Sendable {
    let conversationActive: Bool
    let participantSpeaking: Bool

    init(conversationActive: Bool = false, participantSpeaking: Bool = false) {
        self.conversationActive = conversationActive
        self.participantSpeaking = participantSpeaking
    }
}

/// A process-local projection of the Live conversation lifecycle for L1
/// admission. It has no transcript or identity data: while a session is live,
/// new social initiatives are invalid for every presence observation.
final class L1LiveConversationStateRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var availability = L1SocialAvailability()

    func begin() {
        lock.lock()
        availability = L1SocialAvailability(conversationActive: true)
        lock.unlock()
    }

    func setParticipantSpeaking(_ speaking: Bool) {
        lock.lock()
        guard availability.conversationActive else {
            lock.unlock()
            return
        }
        availability = L1SocialAvailability(conversationActive: true, participantSpeaking: speaking)
        lock.unlock()
    }

    func end() {
        lock.lock()
        availability = L1SocialAvailability()
        lock.unlock()
    }

    func snapshot() -> L1SocialAvailability {
        lock.lock()
        defer { lock.unlock() }
        return availability
    }
}

final class L1DailyWorldMemoryRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: L1DailyWorldMemory?

    func publish(_ memory: L1DailyWorldMemory?) {
        lock.lock()
        self.memory = memory
        lock.unlock()
    }

    func snapshot() -> L1DailyWorldMemory? {
        lock.lock()
        defer { lock.unlock() }
        return memory
    }
}

/// Converts recognized-person observations into sparse L1 cycles. Identity
/// evidence is a wake signal, not a command to speak. Repeated recognition is
/// locally coalesced before Gemma is contacted, and a late response is ignored.
final class L1PresenceThoughtStream: @unchecked Sendable {
    typealias FrameHandler = @Sendable (L1SituationRequest, L1SituationFrame, KnownPersonPresence, UInt64) -> Void

    private struct PresenceState {
        let presence: KnownPersonPresence
        var lastObservedNS: UInt64
        let identityKind: IdentityKind
        let label: String?
    }

    private struct PendingObservation {
        let similarity: Double
        let monotonicNS: UInt64
        let identityKind: IdentityKind
        let label: String?
    }

    private enum IdentityKind: Equatable, Sendable {
        case enrolled
        case pseudonymous
    }

    private struct CachedMemoryContext {
        let context: L1MemoryContext
        let fetchedAtNS: UInt64
    }

    private let queue = DispatchQueue(label: "soma.l1.presence-thought", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var reasoner: GemmaL1SituationRuntime!
    private let onHealth: @Sendable (String, String) -> Void
    private let onFrame: FrameHandler
    private let onBehaviorDirective: @Sendable (L1BehaviorDirective, UInt64) -> Void
    private let onBehaviorThought: @Sendable (L1SituationFrame, UInt64) -> Void
    private let behaviorContextProvider: @Sendable () -> L1BehaviorContext?
    private let memoryContext: L1MemoryContextProvider
    private let runtimeContext: @Sendable () -> L1SituationRuntimeContext
    private let socialAvailability: @Sendable () -> L1SocialAvailability
    private let visualResourceResolver: @Sendable ([String]) -> [L1VisualResource]
    /// Supplies the current camera frame (as an L1VisualResource) so L1 can
    /// actively see the live view rather than only on-request.
    private let currentFrameProvider: @Sendable () -> L1VisualResource?
    /// Supplies collected web material on curiosity topics so L1 can craft a
    /// more grounded, topical opener.
    private let curiosityContextProvider: @Sendable () -> String?
    /// Receives the L1 model's curiosity (information needs) on every cycle.
    private let onCuriosityNeeds: @Sendable ([L1InformationNeed]) -> Void
    /// Receives the L1 model's proposed memories (with the recognized person
    /// entity, when a person is the subject) so they can be persisted. This is
    /// the consumption half of L1 memory consolidation.
    private let onMemoryProposals: @Sendable ([L1MemoryProposal], UUID?) -> Void
    /// Supplies the language detected from the participant's most recent speech,
    /// so a person who speaks first in a language is answered in that language
    /// even without a stored preferred language.
    private let activeLanguageProvider: @Sendable () -> String?
    private var scheduler = KnownPersonSocialOpportunityScheduler()
    private var presences: [UUID: PresenceState] = [:]
    private var nextDeliberationNS: [UUID: UInt64] = [:]
    private var cachedMemoryContexts: [UUID: CachedMemoryContext] = [:]
    private var pendingObservations: [UUID: PendingObservation] = [:]
    private var contextLookupsInFlight: Set<UUID> = []
    private var thoughtStates: [UUID: L1ThoughtState] = [:]
    private var behaviorThoughtState: L1ThoughtState?
    private var priorFrames: [UUID: L1PriorFrame] = [:]
    private var behaviorPriorFrame: L1PriorFrame?
    private var randomState: UInt64 = 0xD1B5_4A32_C9E7_041F
    private var stopped = false
    private var reassessTimer: DispatchSourceTimer?
    private var behaviorAwarenessTimer: DispatchSourceTimer?
    private var consolidationTimer: DispatchSourceTimer?
    /// Monotonic time of the last auxiliary-wake-triggered behavior pass, used
    /// to throttle bursts of E2B wake proposals so they cannot flood the reasoner.
    private var lastAuxiliaryWakeNS: UInt64?
    private let memoryContextRefreshNS: UInt64 = 60_000_000_000
    // Situation reasoning is gated by the social-opportunity scheduler, whose
    // opening delay (0.5-2.4s) only elapses if we keep re-polling it. A
    // 2s tick lets a due opening fire promptly while the actual inference stays
    // throttled to deliberationIntervalNS below.
    private let reassessIntervalNS: UInt64 = 2_000_000_000
    private let presenceCurrentNS: UInt64 = 3_000_000_000
    private let deliberationIntervalNS: UInt64 = 45_000_000_000
    /// Minimum interval between auxiliary-wake-triggered behavior passes. It
    /// matches the interrupt gate's 5s debounce so a burst of E2B wake proposals
    /// cannot flood the reasoner beyond the periodic cadence.
    private let auxiliaryWakeIntervalNS: UInt64 = 5_000_000_000
    /// How often short-term episodes are consolidated (promoted/pruned).
    /// Configurable via SOMA_L1_CONSOLIDATION_SECONDS.
    private var consolidationIntervalNS: UInt64 {
        UInt64(somaEnvDouble("SOMA_L1_CONSOLIDATION_SECONDS", default: 600) * 1_000_000_000)
    }
    /// The periodic L1 baseline awareness pass runs at the idle interval. A
    /// present person is handled by the E2B auxiliary wake path, not by
    /// tightening this timer. Configurable via SOMA_L1_IDLE_CADENCE_SECONDS.
    private var idleBehaviorAwarenessIntervalNS: UInt64 {
        UInt64(somaEnvDouble("SOMA_L1_IDLE_CADENCE_SECONDS", default: 150) * 1_000_000_000)
    }

    init(
        memoryContext: L1MemoryContextProvider,
        runtimeContext: @escaping @Sendable () -> L1SituationRuntimeContext = { .init() },
        socialAvailability: @escaping @Sendable () -> L1SocialAvailability = { .init() },
        visualResourceResolver: @escaping @Sendable ([String]) -> [L1VisualResource] = { _ in [] },
        currentFrameProvider: @escaping @Sendable () -> L1VisualResource? = { nil },
        curiosityContextProvider: @escaping @Sendable () -> String? = { nil },
        onHealth: @escaping @Sendable (String, String) -> Void,
        onFrame: @escaping FrameHandler,
        behaviorContextProvider: @escaping @Sendable () -> L1BehaviorContext? = { nil },
        onBehaviorDirective: @escaping @Sendable (L1BehaviorDirective, UInt64) -> Void = { _, _ in },
        onBehaviorThought: @escaping @Sendable (L1SituationFrame, UInt64) -> Void = { _, _ in },
        toolDefinitions: [OllamaToolDefinition] = [],
        toolExecutor: @escaping @Sendable (String, String) -> String = { _, _ in "{}" },
        onCuriosityNeeds: @escaping @Sendable ([L1InformationNeed]) -> Void = { _ in },
        onMemoryProposals: @escaping @Sendable ([L1MemoryProposal], UUID?) -> Void = { _, _ in },
        activeLanguageProvider: @escaping @Sendable () -> String? = { nil }
    ) throws {
        queue.setSpecific(key: queueKey, value: 1)
        self.memoryContext = memoryContext
        self.runtimeContext = runtimeContext
        self.socialAvailability = socialAvailability
        self.visualResourceResolver = visualResourceResolver
        self.currentFrameProvider = currentFrameProvider
        self.curiosityContextProvider = curiosityContextProvider
        self.onCuriosityNeeds = onCuriosityNeeds
        self.onMemoryProposals = onMemoryProposals
        self.activeLanguageProvider = activeLanguageProvider
        self.onHealth = onHealth
        self.onFrame = onFrame
        self.behaviorContextProvider = behaviorContextProvider
        self.onBehaviorDirective = onBehaviorDirective
        self.onBehaviorThought = onBehaviorThought
        reasoner = try GemmaL1SituationRuntime(
            onHealth: onHealth,
            completion: { [weak self] request, result, completedNS in
                self?.receive(request: request, result: result, at: completedNS)
            },
            toolDefinitions: toolDefinitions,
            toolExecutor: toolExecutor,
            curiosityContextProvider: curiosityContextProvider,
            onCuriosityNeeds: onCuriosityNeeds
        )
        startReassessmentTimer()
        startBehaviorAwarenessTimer()
        startConsolidationTimer()
    }

    private func startConsolidationTimer() {
        let seconds = Double(consolidationIntervalNS) / 1_000_000_000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            self?.consolidateMemory()
        }
        timer.resume()
        consolidationTimer = timer
    }

    private func consolidateMemory() {
        guard !stopped else { return }
        Task { [weak self] in
            await self?.memoryContext.consolidateEpisodes()
        }
    }

    private func startBehaviorAwarenessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.deliberateBehavior(at: DispatchTime.now().uptimeNanoseconds)
            self?.rescheduleBehaviorAwareness(timer)
        }
        timer.resume()
        behaviorAwarenessTimer = timer
        rescheduleBehaviorAwareness(timer)
    }

    /// One-shot rescheduling. The periodic baseline awareness pass always runs
    /// at the idle interval; responsiveness to a present person is provided by
    /// the E2B auxiliary wake path (wakeFromAuxiliary), not by tightening this
    /// periodic timer. This keeps the local model from being called every 30s
    /// on a busy room and lets E2B decide when a prompt pass is warranted.
    private func rescheduleBehaviorAwareness(_ timer: DispatchSourceTimer) {
        let seconds = Double(idleBehaviorAwarenessIntervalNS) / 1_000_000_000
        timer.schedule(deadline: .now() + seconds, repeating: .never)
    }

    private func startReassessmentTimer() {
        let seconds = Double(reassessIntervalNS) / 1_000_000_000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            self?.reassessActivePresences()
        }
        timer.resume()
        reassessTimer = timer
    }

    func observe(_ decision: FaceIdentityRuntimeDecision, label: String?, at monotonicNS: UInt64) {
        let entityID: UUID
        let similarity: Double
        let identityKind: IdentityKind
        switch decision {
        case let .known(id, value, _):
            entityID = id
            similarity = value
            identityKind = .enrolled
        case let .anonymous(id, _, value, _):
            entityID = id
            similarity = value
            identityKind = .pseudonymous
        case let .unknownCandidate(handle, confirmations):
            // When proactive openings with unknown identities are enabled, an
            // unrecognized face is treated as a pseudonymous participant so L1
            // may deliberate and open with it. The entityID is derived from the
            // anonymous handle, matching the participant identity L0 surfaces.
            guard somaEnvBool("SOMA_L1_OPEN_WITH_UNKNOWN", default: false) else { return }
            entityID = FaceIdentityRuntime.pseudonymousEntityID(for: handle)
            similarity = min(Double(confirmations) / 3, 0.99)
            identityKind = .pseudonymous
        case .knownCandidate:
            return
        }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            let observation = PendingObservation(
                similarity: similarity,
                monotonicNS: monotonicNS,
                identityKind: identityKind,
                label: label
            )
            if let cached = cachedMemoryContexts[entityID],
               monotonicNS >= cached.fetchedAtNS,
               monotonicNS - cached.fetchedAtNS < memoryContextRefreshNS {
                process(observation, for: entityID, with: cached.context)
                return
            }
            pendingObservations[entityID] = observation
            guard contextLookupsInFlight.insert(entityID).inserted else { return }
            Task { [weak self] in
                guard let self else { return }
                let context = await memoryContext.context(
                    for: entityID,
                    createPseudonymousEntity: identityKind == .pseudonymous
                )
                queue.async { [weak self] in
                    guard let self, !stopped else { return }
                    contextLookupsInFlight.remove(entityID)
                    cachedMemoryContexts[entityID] = CachedMemoryContext(
                        context: context,
                        fetchedAtNS: DispatchTime.now().uptimeNanoseconds
                    )
                    guard let latest = pendingObservations.removeValue(forKey: entityID) else { return }
                    process(latest, for: entityID, with: context)
                }
            }
        }
    }

    /// Presence transitions are emitted by L0, not inferred from a delayed
    /// L1 request. Remove only active scheduling state; cached local memory
    /// and the rolling thought state remain available on a later arrival.
    func depart(_ entityID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            presences.removeValue(forKey: entityID)
            pendingObservations.removeValue(forKey: entityID)
            nextDeliberationNS.removeValue(forKey: entityID)
            scheduler.endPresence(for: entityID)
        }
    }

    /// A successful MCP person-context write must be visible to the next L1
    /// deliberation immediately; retaining the old 60-second projection would
    /// otherwise let an already-satisfied information mission be reopened.
    func invalidateMemoryContext(for entityID: UUID) {
        let remove: () -> Void = { [weak self] in
            _ = self?.cachedMemoryContexts.removeValue(forKey: entityID)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            remove()
        } else {
            queue.sync(execute: remove)
        }
    }

    func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                await self?.memoryContext.recordSocialContact(
                    .nonverbalInvitation,
                    with: entityID,
                    purpose: "L1 made a brief nonverbal invitation."
                )
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            reassessTimer?.cancel()
            reassessTimer = nil
            presences.removeAll(keepingCapacity: false)
            nextDeliberationNS.removeAll(keepingCapacity: false)
            cachedMemoryContexts.removeAll(keepingCapacity: false)
            pendingObservations.removeAll(keepingCapacity: false)
            contextLookupsInFlight.removeAll(keepingCapacity: false)
            thoughtStates.removeAll(keepingCapacity: false)
            reasoner.stop()
        }
    }

    private func process(
        _ observation: PendingObservation,
        for entityID: UUID,
        with context: L1MemoryContext
    ) {
        let availability = socialAvailability()
        let presence = KnownPersonPresence(
            entityID: entityID,
            recognitionConfidence: min(max(observation.similarity, 0), 1),
            proactiveContactPreference: context.proactiveContactPreference,
            isSpeaking: availability.participantSpeaking,
            conversationActive: availability.conversationActive
        )
        presences[entityID] = PresenceState(
            presence: presence,
            lastObservedNS: observation.monotonicNS,
            identityKind: observation.identityKind,
            label: observation.label
        )
        guard let opportunity = scheduler.observe(
            presence,
            at: observation.monotonicNS,
            unitIntervalDraw: nextUniform()
        ) else { return }
        deliberate(
            entityID: entityID,
            identityKind: observation.identityKind,
            label: observation.label,
            context: context,
            opportunity: opportunity,
            at: observation.monotonicNS
        )
    }

    /// Re-polls the social-opportunity scheduler for every still-current
    /// presence. The scheduler arms its opening at arrival for 0.5-2.4s in the
    /// future and returns nil until that elapses, but stable presence never
    /// emits a new identity transition to re-wake us; without this periodic
    /// reassessment the opening would never fire and L1 would stay silent for
    /// a person who simply remains present. Runs on the L1 queue.
    private func reassessActivePresences() {
        guard !stopped else { return }
        let monotonicNS = DispatchTime.now().uptimeNanoseconds
        let availability = socialAvailability()
        for (entityID, state) in presences {
            guard monotonicNS >= state.lastObservedNS,
                  monotonicNS - state.lastObservedNS <= presenceCurrentNS,
                  let cached = cachedMemoryContexts[entityID],
                  monotonicNS >= cached.fetchedAtNS,
                  monotonicNS - cached.fetchedAtNS < memoryContextRefreshNS else {
                continue
            }
            // The person is confirmed still present. Refresh the observed
            // timestamp so a stable (never-re-arriving) presence stays "current"
            // and completed L1 frames are not discarded as identity_not_current
            // just because no new identity transition arrived.
            presences[entityID]?.lastObservedNS = monotonicNS
            let presence = KnownPersonPresence(
                entityID: entityID,
                recognitionConfidence: state.presence.recognitionConfidence,
                proactiveContactPreference: cached.context.proactiveContactPreference,
                isSpeaking: availability.participantSpeaking,
                conversationActive: availability.conversationActive
            )
            guard let opportunity = scheduler.observe(
                presence,
                at: monotonicNS,
                unitIntervalDraw: nextUniform()
            ) else { continue }
            deliberate(
                entityID: entityID,
                identityKind: state.identityKind,
                label: state.label,
                context: cached.context,
                opportunity: opportunity,
                at: monotonicNS
            )
        }
    }

    private func deliberate(
        entityID: UUID,
        identityKind: IdentityKind,
        label: String?,
        context: L1MemoryContext,
        opportunity: L1SocialOpportunity,
        at monotonicNS: UInt64
    ) {
        let minimumNext = nextDeliberationNS[entityID] ?? 0
        guard monotonicNS >= minimumNext else { return }
        // Presence keeps a compact L1 working state alive. The one-in-flight
        // transport coalesces slow responses; social appropriateness comes
        // from the per-person contact history, not a fixed elapsed-time gate.
        nextDeliberationNS[entityID] = monotonicNS + deliberationIntervalNS
        let evidenceID = "identity:\(entityID.uuidString.lowercased()):\(monotonicNS)"
        let beliefSummary: String
        switch identityKind {
        case .enrolled:
            if let label, !label.isEmpty, label != "unknown" {
                beliefSummary = "An enrolled recognized person (\(label)) is visually present. This is the known identity's name — do not ask for it. No user speech is active in this identity event."
            } else {
                beliefSummary = "An enrolled recognized person is visually present. No name is supplied. No user speech is active in this identity event."
            }
        case .pseudonymous:
            beliefSummary = "A locally pseudonymous recurring person is visually present. No name or biometric material is supplied. No user speech is active in this identity event."
        }
        let environment = runtimeContext()
        let request = L1SituationRequest(
            observedAt: Date(),
            evidenceIDs: [evidenceID],
            beliefSummary: beliefSummary,
            presentEntityIDs: [entityID],
            memory: context.projections,
            informationNeeds: context.informationNeeds,
            rapport: context.rapport,
            preferredLanguageTag: effectiveLanguageTag(for: context),
            priorThoughtState: thoughtStates[entityID],
            priorFrame: priorFrames[entityID],
            contactHistory: context.contactHistory,
            spatialContext: environment.spatialContext,
            dailyWorldMemory: environment.dailyWorldMemory,
            visualResourceOffers: environment.visualResourceOffers,
            visuals: [currentFrameProvider()].compactMap { $0 },
            socialOpportunity: opportunity,
            curiosityContext: curiosityContextProvider(),
            personPreferences: context.personPreferences,
            spokenOpeningTendency: min(max(somaEnvDouble("SOMA_L1_SPOKEN_OPENING_TENDENCY", default: 0.5), 0), 1),
            recalledEpisodes: context.recalledEpisodes
        )
        onHealth(
            "wake",
            "cause=recognized_person; cycle=\(request.cycleID.uuidString.lowercased()); memory=\(context.projections.count); information_needs=\(context.informationNeeds.count); contact=\(context.proactiveContactPreference.rawValue)"
        )
        reasoner.submit(request)
    }

    /// Resolve the language L1 should speak to this person: their stored
    /// preferred language when present, otherwise the language detected from
    /// their most recent speech, otherwise the configured default
    /// (SOMA_L1_DEFAULT_LANGUAGE, default "ko"). This keeps L1's opening and
    /// L2's response in the same language the participant actually uses.
    private func effectiveLanguageTag(for context: L1MemoryContext) -> String? {
        if let tag = context.preferredLanguageTag, !tag.isEmpty { return tag }
        if let tag = activeLanguageProvider(), !tag.isEmpty { return tag }
        let configured = somaEnvString("SOMA_L1_DEFAULT_LANGUAGE", default: "ko")
        return configured.isEmpty ? nil : configured
    }

    /// The periodic situation-awareness inference. It carries the previous
    /// behavior thought state forward so L1 can reason about a trend (e.g. a
    /// fixation that has persisted across several ticks) rather than a single
    /// stateless snapshot. Runs on the L1 queue.
    private func deliberateBehavior(
        at monotonicNS: UInt64,
        auxiliaryWake: L1AuxiliarySemanticInterrupt? = nil
    ) {
        guard !stopped else { return }
        guard let behavior = behaviorContextProvider() else { return }
        let evidenceID = "behavior:\(monotonicNS)"
        let identityNote = behavior.recognizedIdentity.map { " Recognized identity: \($0)." } ?? ""
        let wakeNote = auxiliaryWake.map {
            " Auxiliary wake: situation=\($0.situation.rawValue); reason=\($0.reason.rawValue); score=\(String(format: "%.2f", $0.score)); evidence=\($0.evidence.prefix(120))."
        } ?? ""
        let request = L1SituationRequest(
            observedAt: Date(),
            evidenceIDs: [evidenceID] + (auxiliaryWake.map { ["auxiliary_wake:\($0.requestID)"] } ?? []),
            beliefSummary: "Periodic L0 behavior self-awareness. Attention=\(behavior.attentionState).\(identityNote)\(wakeNote)",
            priorThoughtState: behaviorThoughtState,
            priorFrame: behaviorPriorFrame,
            visuals: [currentFrameProvider()].compactMap { $0 },
            behaviorContext: behavior,
            curiosityContext: curiosityContextProvider()
        )
        onHealth(
            "wake",
            "cause=\(auxiliaryWake == nil ? "behavior_awareness" : "auxiliary_wake"); cycle=\(request.cycleID.uuidString.lowercased()); attention=\(behavior.attentionState); fixation=\(String(format: "%.1f", behavior.fixationSeconds))s; scan=\(behavior.scanActive ? "on" : "off"); face=\(behavior.isFaceTarget ? "yes" : "no"); identity=\(behavior.recognizedIdentity ?? "none")"
        )
        reasoner.submit(request)
    }

    /// Trigger an immediate behavior-awareness pass in response to an auxiliary
    /// (E2B) wake proposal. The proposal is folded into the L1 request as
    /// evidence so the primary L1 cycle can accept or revise it. Throttled to
    /// `auxiliaryWakeIntervalNS` so a burst of proposals cannot flood the
    /// reasoner beyond the periodic cadence.
    func wakeFromAuxiliary(_ interrupt: L1AuxiliarySemanticInterrupt) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = self.lastAuxiliaryWakeNS, now - last < self.auxiliaryWakeIntervalNS {
                return
            }
            self.lastAuxiliaryWakeNS = now
            self.deliberateBehavior(at: now, auxiliaryWake: interrupt)
        }
    }

    private func receive(
        request: L1SituationRequest,
        result: Result<L1SituationFrame, Error>,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard case let .success(frame) = result else { return }
            if !request.informationNeeds.isEmpty {
                onCuriosityNeeds(request.informationNeeds)
            }
            if !frame.memoryProposals.isEmpty {
                onMemoryProposals(frame.memoryProposals, request.socialOpportunity?.entityID)
            }
            if request.visuals.isEmpty, !frame.requestedVisualResourceIDs.isEmpty {
                let resources = visualResourceResolver(frame.requestedVisualResourceIDs)
                guard !resources.isEmpty else {
                    onHealth("visual_request_unavailable", "resources=\(frame.requestedVisualResourceIDs.count)")
                    return
                }
                onHealth("visual_followup", "resources=\(resources.count)")
                reasoner.submit(request.continuing(with: resources))
                return
            }
            guard !socialAvailability().conversationActive else {
                onHealth("discarded", "reason=live_conversation_active")
                return
            }
            // Behavior-awareness pass: no social opportunity, but its behavioral
            // directive is independent and must still reach the L0 layer.
            if request.socialOpportunity == nil {
                if let thoughtState = frame.thoughtState {
                    behaviorThoughtState = thoughtState
                }
                behaviorPriorFrame = Self.priorFrame(from: frame)
                onBehaviorThought(frame, monotonicNS)
                if let directive = frame.behaviorDirective {
                    onHealth("behavior_directive", "action=\(directive.action.rawValue)")
                    onBehaviorDirective(directive, monotonicNS)
                }
                return
            }
            guard let opportunity = request.socialOpportunity,
                  let state = presences[opportunity.entityID],
                  monotonicNS >= state.lastObservedNS,
                  monotonicNS - state.lastObservedNS <= 2_000_000_000 else {
                onHealth("discarded", "reason=identity_not_current")
                return
            }
            if let thoughtState = frame.thoughtState {
                thoughtStates[opportunity.entityID] = thoughtState
            }
            priorFrames[opportunity.entityID] = Self.priorFrame(from: frame)
            onFrame(request, frame, state.presence, monotonicNS)
        }
    }

    private static func priorFrame(from frame: L1SituationFrame) -> L1PriorFrame {
        let decision = frame.socialDecision
        let opening: String?
        switch decision?.openingContent {
        case .question(_, let text): opening = text
        case .greeting, .none: opening = nil
        }
        return L1PriorFrame(
            summary: frame.summary,
            action: decision?.action.rawValue,
            rationale: decision?.rationale,
            opening: opening,
            confidence: decision?.confidence
        )
    }

    private func nextUniform() -> Double {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(randomState >> 11) / Double(1 << 53)
    }
}

/// An immutable callback target for capture and L1 completion queues. It keeps
/// startup ordering out of those queues and avoids treating an unavailable L1
/// transport as a failure of L0 identity perception.
final class L1ThoughtStreamRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: L1PresenceThoughtStream?

    func install(_ stream: L1PresenceThoughtStream) {
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    func observe(_ decision: FaceIdentityRuntimeDecision, label: String?, at monotonicNS: UInt64) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.observe(decision, label: label, at: monotonicNS)
    }

    func depart(_ entityID: UUID) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.depart(entityID)
    }

    func invalidateMemoryContext(for entityID: UUID) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.invalidateMemoryContext(for: entityID)
    }

    func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.recordNonverbalInvitation(with: entityID, at: monotonicNS)
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        stream?.stop()
    }
}
