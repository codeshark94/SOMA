import Foundation

public enum L1ThoughtWakeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case event
    case periodic
}

public enum L1ConsciousnessWorkItem: Equatable, Sendable {
    case thought(L1ThoughtRequest)
    case executive(L1ExecutiveRequest)
}

/// Latest-value priority queue shared by the live transport and deterministic
/// tests. Distinct executive intention episodes are retained in order; event
/// and periodic reflection each coalesce to the newest workspace snapshot.
public struct L1ConsciousnessWorkQueue: Equatable, Sendable {
    private var executives: [L1ExecutiveRequest] = []
    private var eventThought: L1ThoughtRequest?
    private var periodicThought: L1ThoughtRequest?

    public init() {}

    public var executiveCount: Int { executives.count }
    public var hasEventThought: Bool { eventThought != nil }
    public var hasPeriodicThought: Bool { periodicThought != nil }
    public var isEmpty: Bool {
        executives.isEmpty && eventThought == nil && periodicThought == nil
    }

    public mutating func enqueue(
        _ request: L1ThoughtRequest
    ) {
        switch request.wakeKind {
        case .event:
            eventThought = request
            if let periodicThought,
               periodicThought.workspace.revision <= request.workspace.revision {
                self.periodicThought = nil
            }
        case .periodic:
            guard eventThought == nil else { return }
            periodicThought = request
        }
    }

    public mutating func enqueue(
        _ request: L1ExecutiveRequest,
        excludingActiveIntentionID: UUID? = nil
    ) {
        guard request.intention.id != excludingActiveIntentionID,
              !executives.contains(where: { $0.intention.id == request.intention.id }) else {
            return
        }
        executives.append(request)
    }

    public mutating func dequeue() -> L1ConsciousnessWorkItem? {
        if !executives.isEmpty { return .executive(executives.removeFirst()) }
        if let eventThought {
            self.eventThought = nil
            return .thought(eventThought)
        }
        if let periodicThought {
            self.periodicThought = nil
            return .thought(periodicThought)
        }
        return nil
    }

    public mutating func removeAll() {
        executives.removeAll()
        eventThought = nil
        periodicThought = nil
    }
}

public struct L1ThoughtRequest: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let observedAt: Date
    public let wakeKind: L1ThoughtWakeKind
    public let workspace: MentalWorkspaceSnapshot
    public let evidence: [MentalEvidenceEvent]
    public let beliefSummary: String
    public let presentEntityIDs: [UUID]
    public let memory: [RemoteMemoryProjection]
    public let informationNeeds: [L1InformationNeed]
    public let rapport: L1RapportContext?
    public let preferredLanguageTag: String?
    public let recentConversation: [L1ConversationContext]
    public let contactHistory: [L1SocialContactEvent]
    public let spatialContext: L1SpatialContext?
    public let dailyWorldMemory: L1DailyWorldMemory?
    public let visualResourceOffers: [L1VisualResourceOffer]
    public let visuals: [L1VisualResource]
    public let socialOpportunity: L1SocialOpportunity?
    public let contactPattern: L1ContactPattern?
    public let behaviorContext: L1BehaviorContext?
    public let curiosityContext: String?
    public let personPreferences: String?
    public let spokenOpeningTendency: Double
    public let recalledEpisodes: [String]
    public let perceptionAgeSeconds: Double

    public init(
        cycleID: UUID = UUID(),
        observedAt: Date,
        wakeKind: L1ThoughtWakeKind,
        workspace: MentalWorkspaceSnapshot,
        evidence: [MentalEvidenceEvent],
        beliefSummary: String,
        presentEntityIDs: [UUID] = [],
        memory: [RemoteMemoryProjection] = [],
        informationNeeds: [L1InformationNeed] = [],
        rapport: L1RapportContext? = nil,
        preferredLanguageTag: String? = nil,
        recentConversation: [L1ConversationContext] = [],
        contactHistory: [L1SocialContactEvent] = [],
        spatialContext: L1SpatialContext? = nil,
        dailyWorldMemory: L1DailyWorldMemory? = nil,
        visualResourceOffers: [L1VisualResourceOffer] = [],
        visuals: [L1VisualResource] = [],
        socialOpportunity: L1SocialOpportunity? = nil,
        contactPattern: L1ContactPattern? = nil,
        behaviorContext: L1BehaviorContext? = nil,
        curiosityContext: String? = nil,
        personPreferences: String? = nil,
        spokenOpeningTendency: Double = 0.7,
        recalledEpisodes: [String] = [],
        perceptionAgeSeconds: Double = 0
    ) {
        self.cycleID = cycleID
        self.observedAt = observedAt
        self.wakeKind = wakeKind
        self.workspace = workspace
        self.evidence = Array(evidence.prefix(32))
        self.beliefSummary = String(beliefSummary.prefix(8_192))
        self.presentEntityIDs = Array(presentEntityIDs.prefix(16))
        self.memory = Array(memory.prefix(128))
        self.informationNeeds = Array(informationNeeds.prefix(32))
        self.rapport = rapport
        self.preferredLanguageTag = preferredLanguageTag.map { String($0.prefix(35)) }
        self.recentConversation = Array(recentConversation.prefix(128))
        self.contactHistory = Array(contactHistory.prefix(16))
        self.spatialContext = spatialContext
        self.dailyWorldMemory = dailyWorldMemory
        self.visualResourceOffers = Array(visualResourceOffers.prefix(8))
        self.visuals = Array(visuals.prefix(2))
        self.socialOpportunity = socialOpportunity
        self.contactPattern = contactPattern
        self.behaviorContext = behaviorContext
        self.curiosityContext = curiosityContext.map { String($0.prefix(2_000)) }
        self.personPreferences = personPreferences.map { String($0.prefix(1_500)) }
        self.spokenOpeningTendency = min(max(spokenOpeningTendency, 0), 1)
        self.recalledEpisodes = Array(recalledEpisodes.prefix(8)).map { String($0.prefix(1_200)) }
        self.perceptionAgeSeconds = max(perceptionAgeSeconds, 0)
    }

    public var availableEvidenceIDs: Set<String> {
        Set(workspace.processedEvidenceIDs + evidence.map(\.id))
    }

    public func continuing(with visuals: [L1VisualResource]) -> Self {
        Self(
            cycleID: cycleID,
            observedAt: observedAt,
            wakeKind: wakeKind,
            workspace: workspace,
            evidence: evidence,
            beliefSummary: beliefSummary,
            presentEntityIDs: presentEntityIDs,
            memory: memory,
            informationNeeds: informationNeeds,
            rapport: rapport,
            preferredLanguageTag: preferredLanguageTag,
            recentConversation: recentConversation,
            contactHistory: contactHistory,
            spatialContext: spatialContext,
            dailyWorldMemory: dailyWorldMemory,
            visualResourceOffers: visualResourceOffers,
            visuals: visuals,
            socialOpportunity: socialOpportunity,
            contactPattern: contactPattern,
            behaviorContext: behaviorContext,
            curiosityContext: curiosityContext,
            personPreferences: personPreferences,
            spokenOpeningTendency: spokenOpeningTendency,
            recalledEpisodes: recalledEpisodes,
            perceptionAgeSeconds: perceptionAgeSeconds
        )
    }
}

public enum L1ExecutiveAction: String, Codable, CaseIterable, Hashable, Sendable {
    case noAction = "no_action"
    case nonverbalInvitation = "nonverbal_invitation"
    case spokenOpening = "spoken_opening"
    case resumeScanning = "resume_scanning"
    case seekPeople = "seek_people"
    case acknowledgePerson = "acknowledge_person"
    case inspectAttentionTarget = "inspect_attention_target"
}

public struct L1ExecutiveRequest: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let observedAt: Date
    public let workspaceRevision: UInt64
    public let intention: MentalIntention
    public let foregroundThought: ThoughtCandidate
    public let relatedHypotheses: [MentalHypothesis]
    public let context: MentalContextState
    public let availableActions: [L1ExecutiveAction]
    public let socialOpportunity: L1SocialOpportunity?
    public let behaviorContext: L1BehaviorContext?
    public let informationNeeds: [L1InformationNeed]
    public let contactHistory: [L1SocialContactEvent]
    public let rapport: L1RapportContext?
    public let preferredLanguageTag: String?
    public let personPreferences: String?
    public let memorySummaries: [String]
    public let recalledEpisodes: [String]
    public let evidenceIDs: [String]

    public init(
        cycleID: UUID = UUID(),
        observedAt: Date,
        workspaceRevision: UInt64,
        intention: MentalIntention,
        foregroundThought: ThoughtCandidate,
        relatedHypotheses: [MentalHypothesis],
        context: MentalContextState,
        availableActions: [L1ExecutiveAction],
        socialOpportunity: L1SocialOpportunity? = nil,
        behaviorContext: L1BehaviorContext? = nil,
        informationNeeds: [L1InformationNeed] = [],
        contactHistory: [L1SocialContactEvent] = [],
        rapport: L1RapportContext? = nil,
        preferredLanguageTag: String? = nil,
        personPreferences: String? = nil,
        memorySummaries: [String] = [],
        recalledEpisodes: [String] = [],
        evidenceIDs: [String]
    ) {
        self.cycleID = cycleID
        self.observedAt = observedAt
        self.workspaceRevision = workspaceRevision
        self.intention = intention
        self.foregroundThought = foregroundThought
        self.relatedHypotheses = Array(relatedHypotheses.prefix(16))
        self.context = context
        self.availableActions = Array(availableActions.uniqued().prefix(16))
        self.socialOpportunity = socialOpportunity
        self.behaviorContext = behaviorContext
        self.informationNeeds = Array(informationNeeds.prefix(32))
        self.contactHistory = Array(contactHistory.prefix(16))
        self.rapport = rapport
        self.preferredLanguageTag = preferredLanguageTag.map { String($0.prefix(35)) }
        self.personPreferences = personPreferences.map { String($0.prefix(1_500)) }
        self.memorySummaries = Array(memorySummaries.prefix(24)).map { String($0.prefix(1_024)) }
        self.recalledEpisodes = Array(recalledEpisodes.prefix(8)).map { String($0.prefix(1_200)) }
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(64)).map { String($0.prefix(256)) }
    }
}

public struct L1ExecutiveDecision: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let expectedRevision: UInt64
    public let intentionEpisodeID: UUID
    public let action: L1ExecutiveAction
    public let confidence: Double
    public let rationale: String
    public let opening: String?
    public let motiveID: UUID?

    public init(
        cycleID: UUID,
        expectedRevision: UInt64,
        intentionEpisodeID: UUID,
        action: L1ExecutiveAction,
        confidence: Double,
        rationale: String,
        opening: String? = nil,
        motiveID: UUID? = nil
    ) {
        self.cycleID = cycleID
        self.expectedRevision = expectedRevision
        self.intentionEpisodeID = intentionEpisodeID
        self.action = action
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.rationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
        self.opening = opening.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024)) }
        self.motiveID = motiveID
    }
}

public enum ConsciousnessResponseError: Error, Equatable, Sendable {
    case malformedJSON
    case forbiddenThoughtField(String)
    case validationFailed([String])
}

extension ConsciousnessResponseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            "Malformed consciousness response JSON."
        case let .forbiddenThoughtField(field):
            "L1a response contained forbidden field: \(field)."
        case let .validationFailed(failures):
            "Consciousness response validation failed: \(failures.joined(separator: "; "))."
        }
    }
}

public enum L1ThoughtResponseDecoder {
    private static let allowedKeys: Set<String> = [
        "expected_revision", "evidence_ids", "inner_monologue", "channel",
        "continuity", "parent_thought_id", "confidence", "salience", "novelty",
        "hypothesis_mutations", "drive_signal", "intention",
        "requested_visual_resource_ids", "memory_proposals",
    ]
    private static let forbiddenKeys: Set<String> = [
        "action", "behavior_directive", "opening", "rationale",
        "social_decision", "executive_decision",
    ]

    public static func decode(_ data: Data, for request: L1ThoughtRequest) throws -> L1ThoughtUpdate {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConsciousnessResponseError.malformedJSON
        }
        if let forbidden = forbiddenKeys.first(where: { object.keys.contains($0) }) {
            throw ConsciousnessResponseError.forbiddenThoughtField(forbidden)
        }
        if let unknown = object.keys.first(where: { !allowedKeys.contains($0) }) {
            throw ConsciousnessResponseError.validationFailed(["unknown thought field: \(unknown)"])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom(Self.responseKey)
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let update: L1ThoughtUpdate
        do {
            update = try decoder.decode(L1ThoughtUpdate.self, from: data)
        } catch {
            throw ConsciousnessResponseError.malformedJSON
        }
        var failures: [String] = []
        if update.expectedRevision != request.workspace.revision {
            failures.append("workspace revision mismatch")
        }
        if update.innerMonologue.isEmpty { failures.append("inner monologue is required") }
        if update.evidenceIDs.isEmpty { failures.append("evidence is required") }
        let available = request.availableEvidenceIDs
        if !Set(update.evidenceIDs).isSubset(of: available) {
            failures.append("thought references unavailable evidence")
        }
        let hypothesisIDs = Set(request.workspace.hypotheses.map(\.id))
        for mutation in update.hypothesisMutations {
            if !Set(mutation.evidenceIDs).isSubset(of: available) {
                failures.append("hypothesis mutation references unavailable evidence")
            }
            switch mutation.operation {
            case .propose:
                if mutation.seed == nil { failures.append("proposed hypothesis requires a seed") }
            case .support, .contradict, .resolve, .abandon:
                guard let id = mutation.hypothesisID, hypothesisIDs.contains(id) else {
                    failures.append("hypothesis mutation references an unknown hypothesis")
                    continue
                }
            }
        }
        if let parent = update.parentThoughtID,
           !request.workspace.thoughtCandidates.contains(where: { $0.id == parent }) {
            failures.append("thought parent is unavailable")
        }
        if let intention = update.intention,
           !Set(intention.evidenceIDs).isSubset(of: available) {
            failures.append("intention references unavailable evidence")
        }
        for proposal in update.memoryProposals where !Set(proposal.evidenceIDs).isSubset(of: available) {
            failures.append("memory proposal references unavailable evidence")
        }
        guard failures.isEmpty else {
            throw ConsciousnessResponseError.validationFailed(failures)
        }
        return update
    }

    private static func responseKey(_ path: [CodingKey]) -> CodingKey {
        let source = path.last?.stringValue ?? ""
        let words = source.split(separator: "_").map(String.init)
        guard words.count > 1 else { return ConsciousnessCodingKey(source) }
        var result = words[0]
        for word in words.dropFirst() {
            switch word {
            case "id": result += "ID"
            case "ids": result += "IDs"
            default:
                result += word.prefix(1).uppercased() + word.dropFirst()
            }
        }
        return ConsciousnessCodingKey(result)
    }
}

public enum L1ExecutiveResponseDecoder {
    public static func decode(_ data: Data, for request: L1ExecutiveRequest) throws -> L1ExecutiveDecision {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConsciousnessResponseError.malformedJSON
        }
        let allowedKeys: Set<String> = [
            "cycle_id", "expected_revision", "intention_episode_id", "action",
            "confidence", "rationale", "opening", "motive_id",
        ]
        if let unknown = object.keys.first(where: { !allowedKeys.contains($0) }) {
            throw ConsciousnessResponseError.validationFailed(["unknown executive field: \(unknown)"])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom(Self.responseKey)
        let decision: L1ExecutiveDecision
        do {
            decision = try decoder.decode(L1ExecutiveDecision.self, from: data)
        } catch {
            throw ConsciousnessResponseError.malformedJSON
        }
        var failures: [String] = []
        if decision.cycleID != request.cycleID { failures.append("cycle ID mismatch") }
        if decision.expectedRevision != request.workspaceRevision {
            failures.append("workspace revision mismatch")
        }
        if decision.intentionEpisodeID != request.intention.id {
            failures.append("intention episode mismatch")
        }
        if !request.availableActions.contains(decision.action) {
            failures.append("action is unavailable")
        }
        if decision.rationale.isEmpty { failures.append("rationale is required") }
        if decision.action == .spokenOpening {
            if request.socialOpportunity == nil { failures.append("spoken opening requires a social opportunity") }
            if decision.opening?.isEmpty != false { failures.append("spoken opening content is required") }
            if let motiveID = decision.motiveID {
                if !request.informationNeeds.contains(where: {
                    $0.motiveID == motiveID && $0.permitsProactiveSpokenOpening
                }) {
                    failures.append("spoken opening motive is unavailable")
                }
            } else {
                failures.append("spoken opening motive is required")
            }
        } else if decision.opening != nil || decision.motiveID != nil {
            failures.append("non-spoken action cannot carry an opening")
        }
        guard failures.isEmpty else {
            throw ConsciousnessResponseError.validationFailed(failures)
        }
        return decision
    }

    private static func responseKey(_ path: [CodingKey]) -> CodingKey {
        let source = path.last?.stringValue ?? ""
        let words = source.split(separator: "_").map(String.init)
        guard words.count > 1 else { return ConsciousnessCodingKey(source) }
        var result = words[0]
        for word in words.dropFirst() {
            switch word {
            case "id": result += "ID"
            case "ids": result += "IDs"
            default:
                result += word.prefix(1).uppercased() + word.dropFirst()
            }
        }
        return ConsciousnessCodingKey(result)
    }
}

private struct ConsciousnessCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
