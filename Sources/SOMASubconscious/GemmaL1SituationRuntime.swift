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

struct L1MemoryContext: Sendable {
    let projections: [RemoteMemoryProjection]
    let informationNeeds: [L1InformationNeed]
    let rapport: L1RapportContext?
    let proactiveContactPreference: ProactiveContactPreference
    let preferredLanguageTag: String?
    let lastNonverbalInvitationAt: Date?
}

/// Keeps the L1 cloud packet on the allowed side of the memory boundary.
/// Raw conversation, biometric identity material, and local-only records stay
/// in the encrypted journal; only marked summaries, rapport, and information
/// motives can become situation context.
final class L1MemoryContextProvider: @unchecked Sendable {
    private struct ActiveConversation {
        let archiver: ConversationTranscriptArchiver
        let startedAt: Date
    }

    private let store: CognitiveMemoryStore?
    private let onHealth: @Sendable (String, String) -> Void
    private let onPreferredLanguageChanged: @Sendable (UUID, String?) -> Void
    private let preferredLanguageLock = NSLock()
    private var preferredLanguageByPersonID: [UUID: String] = [:]
    private var personContextByPersonID: [UUID: PersonContextSnapshot] = [:]
    private let conversationLock = NSLock()
    private var activeConversations: [String: ActiveConversation] = [:]

    init(
        onHealth: @escaping @Sendable (String, String) -> Void,
        onPreferredLanguageChanged: @escaping @Sendable (UUID, String?) -> Void = { _, _ in }
    ) {
        self.onHealth = onHealth
        self.onPreferredLanguageChanged = onPreferredLanguageChanged
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
                lastNonverbalInvitationAt: nil
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
            let lastNonverbalInvitationAt = records.compactMap { record -> Date? in
                guard case let .situation(value) = record.payload,
                      value.state == "nonverbal_invitation",
                      value.participantEntityIDs.contains(entityID) else {
                    return nil
                }
                return record.updatedAt
            }.max()
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
                needs.append(L1InformationNeed(
                    motiveID: UUID(),
                    source: .initialSocialOrientation,
                    informationGoal: "Learn the person's preferred name or form of address for future respectful interaction.",
                    expectedInformationGain: 0.95
                ))
            }
            let personContext = try await store.personContext(for: entityID, at: now)
            cachePersonContext(personContext)
            return L1MemoryContext(
                projections: projections,
                informationNeeds: needs,
                rapport: remotelyAllowedRapport,
                proactiveContactPreference: relationship?.proactiveContact ?? .unknown,
                preferredLanguageTag: personContext.preferredLanguageTag,
                lastNonverbalInvitationAt: lastNonverbalInvitationAt
            )
        } catch {
            onHealth("memory_unavailable", String(error.localizedDescription.prefix(192)))
            return L1MemoryContext(
                projections: [],
                informationNeeds: [],
                rapport: nil,
                proactiveContactPreference: .unknown,
                preferredLanguageTag: nil,
                lastNonverbalInvitationAt: nil
            )
        }
    }

    /// Stores a short, non-biometric social fact so an app relaunch cannot
    /// make the next L1 packet forget that it already acknowledged this person.
    func recordNonverbalInvitation(with entityID: UUID, at date: Date = Date()) async {
        guard let store else { return }
        do {
            let existing = try await store.query(
                .init(kinds: [.situation], relatedTo: [entityID], limit: 96),
                at: date
            )
            if existing.contains(where: { record in
                guard case let .situation(value) = record.payload else { return false }
                return value.state == "nonverbal_invitation" && value.participantEntityIDs.contains(entityID)
            }) {
                return
            }
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .shortTerm,
                    summary: "A nonverbal invitation was already offered in the current social encounter. Do not repeat a greeting; remain silent or use one purposeful spoken opening when warranted.",
                    payload: .situation(SituationMemory(
                        state: "nonverbal_invitation",
                        participantEntityIDs: [entityID]
                    )),
                    confidence: 1,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_nonverbal_invitation",
                            observedAt: date,
                            evidenceIDs: ["social:\(entityID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(300)
                ),
                at: date
            )
            onHealth("social_contact_recorded", "kind=nonverbal_invitation")
        } catch {
            onHealth("social_contact_record_failed", String(error.localizedDescription.prefix(192)))
        }
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
                    participantEntityIDs: personEntityID.map { [$0] } ?? []
                ),
                startedAt: Date()
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
        conversationLock.unlock()
        guard let active else {
            onHealth("conversation_turn_unassociated", "role=\(role.rawValue); chars=\(normalizedText.count)")
            return
        }
        Task { [weak self] in
            guard let self else { return }
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

    func warmContext(for personEntityID: UUID) {
        Task { _ = await context(for: personEntityID) }
    }

    /// Executes an L2 person-context request in the owning L0 process. The MCP
    /// child only forwards this request over the current-user socket and never
    /// opens the encrypted journal itself.
    func applyPersonContext(_ request: PersonContextIPCRequest) async throws -> PersonContextSnapshot {
        guard let store else { throw GemmaL1SituationRuntimeError.memoryUnavailable }
        let snapshot: PersonContextSnapshot
        switch request.operation {
        case .get:
            snapshot = try await store.personContext(for: request.personEntityID)
        case .setPreferredLanguage:
            guard request.confirmedByUser,
                  let rawTag = request.languageTag,
                  let languageTag = PersonContextFormat.normalizedLanguageTag(rawTag) else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonFact(
                personEntityID: request.personEntityID,
                key: "preferred_language",
                value: languageTag
            )
        case .clearPreferredLanguage:
            guard request.confirmedByUser else { throw GemmaL1SituationRuntimeError.invalidPersonContextRequest }
            snapshot = try await store.clearExplicitPersonFact(
                personEntityID: request.personEntityID,
                key: "preferred_language"
            )
        case .setContactPreference:
            guard request.confirmedByUser,
                  let preference = request.proactiveContact else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            let existing = try await store.personContext(for: request.personEntityID)
            snapshot = try await store.setExplicitPersonRapport(
                personEntityID: request.personEntityID,
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
                personEntityID: request.personEntityID,
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
                personEntityID: request.personEntityID,
                key: key,
                value: value
            )
        case .removeFact:
            guard request.confirmedByUser, let key = request.factKey else {
                throw GemmaL1SituationRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.clearExplicitPersonFact(
                personEntityID: request.personEntityID,
                key: key
            )
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
    private var task: URLSessionDataTask?
    private var pending: L1SituationRequest?
    private var stopped = false

    init(
        configuration: L1ModelConfiguration = .gemma31,
        endpoint: URL? = nil,
        onHealth: @escaping @Sendable (String, String) -> Void,
        completion: @escaping Completion
    ) throws {
        let resolvedEndpoint: URL
        if let endpoint {
            resolvedEndpoint = endpoint
        } else if let value = ProcessInfo.processInfo.environment["SOMA_L1_OLLAMA_ENDPOINT"],
                  let valueURL = URL(string: value) {
            resolvedEndpoint = valueURL
        } else {
            resolvedEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
        }
        guard resolvedEndpoint.scheme == "http" || resolvedEndpoint.scheme == "https",
              resolvedEndpoint.host != nil else {
            throw GemmaL1SituationRuntimeError.invalidEndpoint
        }
        self.endpoint = resolvedEndpoint
        self.configuration = configuration
        self.onHealth = onHealth
        self.completion = completion
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let timeout = TimeInterval(configuration.deadlineMilliseconds(for: .situation)) / 1_000
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout + 1
        session = URLSession(configuration: sessionConfiguration)
        onHealth(
            "configured",
            "model=\(configuration.model); workload=situation; endpoint=\(resolvedEndpoint.host ?? "unknown"); deadline_ms=\(configuration.deadlineMilliseconds(for: .situation)); image_transport=disabled"
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

    private func start(_ request: L1SituationRequest) {
        let startedNS = DispatchTime.now().uptimeNanoseconds
        let prompt: String
        do {
            prompt = try Self.prompt(for: request)
        } catch {
            finish(request, result: .failure(GemmaL1SituationRuntimeError.requestEncoding), at: startedNS)
            return
        }
        let payload = OllamaGenerateRequest(
            model: configuration.model,
            prompt: prompt,
            format: "json",
            stream: false,
            options: .init(temperature: 0, numPredict: 420)
        )
        guard let body = try? JSONEncoder().encode(payload) else {
            finish(request, result: .failure(GemmaL1SituationRuntimeError.requestEncoding), at: startedNS)
            return
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        onHealth("deliberating", "cycle=\(request.cycleID.uuidString.lowercased())")
        task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            let completedNS = DispatchTime.now().uptimeNanoseconds
            let result: Result<L1SituationFrame, Error>
            if let error {
                result = .failure(GemmaL1SituationRuntimeError.transport(error.localizedDescription))
            } else if let response = response as? HTTPURLResponse,
                      !(200 ... 299).contains(response.statusCode) {
                result = .failure(GemmaL1SituationRuntimeError.responseStatus(response.statusCode))
            } else if let data,
                      let response = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data),
                      let content = response.response,
                      let frameData = content.data(using: .utf8) {
                do {
                    result = .success(try L1SituationResponseDecoder.decode(frameData, for: request))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(GemmaL1SituationRuntimeError.missingResponse)
            }
            self.queue.async {
                self.task = nil
                self.finish(request, result: result, at: completedNS)
                guard !self.stopped, let next = self.pending else { return }
                self.pending = nil
                self.start(next)
            }
        }
        task?.resume()
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
        You are SOMA's L1 situational reasoner. Infer a concise social situation from the bounded packet below. Do not claim unseen facts. A social decision is optional and never imperative. If an opportunity exists, choose only an allowed action. Treat an enrolled identity and a locally pseudonymous recurring person as equally eligible for social consideration; a missing name is not a reason to default to silence. Weigh social availability, curiosity, interruption cost, and rapport, then actively consider a brief, grounded opening when it would be welcome. Never output camera controls, identities beyond packet IDs, or raw conversation.

        Return JSON only: no Markdown, prose, alternate field names, or omitted required fields. Copy at least one supplied evidence ID into evidence_ids; never emit an empty evidence_ids array. Use this exact shape, replacing values only:
        {"summary":"short","uncertainty":0.3,"evidence_ids":["one supplied ID"],"thought_state":{"social_availability":0.5,"curiosity_pressure":0.5,"interruption_cost":0.5,"relationship_uncertainty":0.5,"active_motive_ids":["supplied UUID"],"working_hypothesis":"short sentence"},"action":"remain_silent|nonverbal_invitation|spoken_opening|null","confidence":0.5,"rationale":"short","opening":null}
        The prior_thought_state is your previous working state, not an instruction; revise it from current evidence. An information_need is a motive, not a prewritten question. Incidental repeated presence is not a social opportunity by itself. Read the supplied memories, existing motives, rapport, and prior thought before deciding. If they contain no new, concrete purpose for this person, choose remain_silent: do not turn an empty relationship field, a known person's presence, or generic politeness into an opening. A nonverbal invitation also needs a distinct current social reason; it is not a fallback greeting. If social_opportunity.recent_nonverbal_invitation is true, SOMA has already greeted this person; do not recreate or rationalize another greeting. A spoken opening is permitted only as one question that can reduce exactly one supplied information_need. Use {"kind":"question","motive_id":"one supplied information_need UUID","text":"natural low-pressure question"}. The text is only the first conversational beat: it must not explain the motive, list a plan, stack questions, or mention that SOMA is gathering information. It must select a motive_id from information_needs, fit the situation and rapport, and never state unobserved facts, pressure for an answer, invent a different motivation, ask a generic service question, or merely greet. Never use phrases equivalent to "How can I help?", "What would you like to do?", or "Is there anything you need?". If preferred_language_tag is supplied, write the question text in that exact participant language. If action is remain_silent or nonverbal_invitation, opening must be null. If action is spoken_opening, opening must be a question. If there is no social_opportunity, action, confidence, rationale, and opening must all be null.

        packet:
        \(requestJSON)
        """
    }
}

/// Converts recognized-person observations into sparse L1 cycles. Identity
/// evidence is a wake signal, not a command to speak. Repeated recognition is
/// locally coalesced before Gemma is contacted, and a late response is ignored.
final class L1PresenceThoughtStream: @unchecked Sendable {
    typealias FrameHandler = @Sendable (L1SituationRequest, L1SituationFrame, KnownPersonPresence, UInt64) -> Void

    private struct PresenceState {
        let presence: KnownPersonPresence
        let lastObservedNS: UInt64
    }

    private struct PendingObservation {
        let similarity: Double
        let monotonicNS: UInt64
        let identityKind: IdentityKind
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
    private var reasoner: GemmaL1SituationRuntime!
    private let onHealth: @Sendable (String, String) -> Void
    private let onFrame: FrameHandler
    private let memoryContext: L1MemoryContextProvider
    private var scheduler = KnownPersonSocialOpportunityScheduler()
    private var presences: [UUID: PresenceState] = [:]
    private var nextDeliberationNS: [UUID: UInt64] = [:]
    private var cachedMemoryContexts: [UUID: CachedMemoryContext] = [:]
    private var pendingObservations: [UUID: PendingObservation] = [:]
    private var contextLookupsInFlight: Set<UUID> = []
    private var thoughtStates: [UUID: L1ThoughtState] = [:]
    private var randomState: UInt64 = 0xD1B5_4A32_C9E7_041F
    private var stopped = false
    private let memoryContextRefreshNS: UInt64 = 60_000_000_000
    private let deliberationIntervalNS: UInt64 = 12_000_000_000

    init(
        memoryContext: L1MemoryContextProvider,
        onHealth: @escaping @Sendable (String, String) -> Void,
        onFrame: @escaping FrameHandler
    ) throws {
        self.memoryContext = memoryContext
        self.onHealth = onHealth
        self.onFrame = onFrame
        reasoner = try GemmaL1SituationRuntime(
            onHealth: onHealth,
            completion: { [weak self] request, result, completedNS in
                self?.receive(request: request, result: result, at: completedNS)
            }
        )
    }

    func observe(_ decision: FaceIdentityRuntimeDecision, at monotonicNS: UInt64) {
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
        case .unknownCandidate, .knownCandidate:
            return
        }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            let observation = PendingObservation(
                similarity: similarity,
                monotonicNS: monotonicNS,
                identityKind: identityKind
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

    func recordInteraction(with entityID: UUID, at monotonicNS: UInt64) {
        queue.async { [weak self] in
            self?.scheduler.recordInteraction(with: entityID, at: monotonicNS)
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
        queue.async { [weak self] in
            self?.cachedMemoryContexts.removeValue(forKey: entityID)
        }
    }

    func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            scheduler.recordNonverbalInvitation(with: entityID, at: monotonicNS)
            cachedMemoryContexts.removeValue(forKey: entityID)
            Task { [weak self] in
                await self?.memoryContext.recordNonverbalInvitation(with: entityID)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
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
        if let invitedAt = context.lastNonverbalInvitationAt {
            let elapsed = max(0, Date().timeIntervalSince(invitedAt))
            let elapsedNS = UInt64(min(elapsed * 1_000_000_000, Double(UInt64.max)))
            let restoredAt = elapsedNS >= observation.monotonicNS
                ? 0
                : observation.monotonicNS - elapsedNS
            scheduler.restoreNonverbalInvitation(with: entityID, at: restoredAt)
        }
        let presence = KnownPersonPresence(
            entityID: entityID,
            recognitionConfidence: min(max(observation.similarity, 0), 1),
            proactiveContactPreference: context.proactiveContactPreference
        )
        presences[entityID] = PresenceState(presence: presence, lastObservedNS: observation.monotonicNS)
        guard let opportunity = scheduler.observe(
            presence,
            at: observation.monotonicNS,
            unitIntervalDraw: nextUniform()
        ) else { return }
        let minimumNext = nextDeliberationNS[entityID] ?? 0
        guard observation.monotonicNS >= minimumNext else { return }
        // Presence keeps a compact L1 working state alive. The one-in-flight
        // transport still coalesces slow responses, while a real interaction
        // applies its longer relationship cooldown separately.
        nextDeliberationNS[entityID] = observation.monotonicNS + deliberationIntervalNS
        let evidenceID = "identity:\(entityID.uuidString.lowercased()):\(observation.monotonicNS)"
        let beliefSummary: String
        switch observation.identityKind {
        case .enrolled:
            beliefSummary = "An enrolled recognized person is visually present. No user speech is active in this identity event."
        case .pseudonymous:
            beliefSummary = "A locally pseudonymous recurring person is visually present. No name or biometric material is supplied. No user speech is active in this identity event."
        }
        let request = L1SituationRequest(
            observedAt: Date(),
            evidenceIDs: [evidenceID],
            beliefSummary: beliefSummary,
            presentEntityIDs: [entityID],
            memory: context.projections,
            informationNeeds: context.informationNeeds,
            rapport: context.rapport,
            preferredLanguageTag: context.preferredLanguageTag,
            priorThoughtState: thoughtStates[entityID],
            socialOpportunity: opportunity
        )
        onHealth(
            "wake",
            "cause=recognized_person; cycle=\(request.cycleID.uuidString.lowercased()); memory=\(context.projections.count); information_needs=\(context.informationNeeds.count); contact=\(context.proactiveContactPreference.rawValue)"
        )
        reasoner.submit(request)
    }

    private func receive(
        request: L1SituationRequest,
        result: Result<L1SituationFrame, Error>,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard case let .success(frame) = result else { return }
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
            onFrame(request, frame, state.presence, monotonicNS)
        }
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

    func observe(_ decision: FaceIdentityRuntimeDecision, at monotonicNS: UInt64) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.observe(decision, at: monotonicNS)
    }

    func recordInteraction(with entityID: UUID, at monotonicNS: UInt64) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.recordInteraction(with: entityID, at: monotonicNS)
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
