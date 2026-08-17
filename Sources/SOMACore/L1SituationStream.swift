import Foundation

public enum L1Workload: String, Codable, CaseIterable, Hashable, Sendable {
    case situation
    case memoryConsolidation = "memory_consolidation"
}

public struct L1ModelConfiguration: Codable, Equatable, Sendable {
    public let model: String
    public let situationDeadlineMilliseconds: UInt64
    public let consolidationDeadlineMilliseconds: UInt64
    /// How readily L1 opens a spoken conversation despite the person appearing
    /// busy/focused. Range 0...1, from SOMA_L1_SPOKEN_OPENING_TENDENCY.
    public let spokenOpeningTendency: Double

    public init(
        situationDeadlineMilliseconds: UInt64 = 20_000,
        consolidationDeadlineMilliseconds: UInt64 = 60_000,
        spokenOpeningTendency: Double = 0.5
    ) {
        precondition(situationDeadlineMilliseconds > 0)
        precondition(consolidationDeadlineMilliseconds >= situationDeadlineMilliseconds)
        let configuredModel = ProcessInfo.processInfo.environment["SOMA_L1_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (configuredModel?.isEmpty == false ? configuredModel : "gemma4:31b-cloud")!
        self.situationDeadlineMilliseconds = situationDeadlineMilliseconds
        self.consolidationDeadlineMilliseconds = consolidationDeadlineMilliseconds
        if let raw = ProcessInfo.processInfo.environment["SOMA_L1_SPOKEN_OPENING_TENDENCY"],
           let value = Double(raw) {
            self.spokenOpeningTendency = min(max(value, 0), 1)
        } else {
            self.spokenOpeningTendency = min(max(spokenOpeningTendency, 0), 1)
        }
    }

    public static let gemma31 = L1ModelConfiguration()

    public func deadlineMilliseconds(for workload: L1Workload) -> UInt64 {
        switch workload {
        case .situation: situationDeadlineMilliseconds
        case .memoryConsolidation: consolidationDeadlineMilliseconds
        }
    }
}

public enum L1VisualProjection: String, Codable, CaseIterable, Hashable, Sendable {
    case currentView = "current_view"
    case sphericalAtlas = "spherical_atlas"
    case changeOverlay = "change_overlay"
}

/// The request references an expiring local visual resource. The Gemma adapter
/// decides how to attach it; image bytes never enter scalar L0 traces.
public struct L1VisualResource: Codable, Equatable, Sendable {
    public let resourceID: String
    public let projection: L1VisualProjection
    public let localPath: String
    public let expiresAt: Date

    public init(resourceID: String, projection: L1VisualProjection, localPath: String, expiresAt: Date) {
        self.resourceID = String(resourceID.prefix(256))
        self.projection = projection
        self.localPath = localPath
        self.expiresAt = expiresAt
    }
}

/// A visual resource L1 may explicitly request for one follow-up inference.
/// Offers carry no local path or pixel data; the owning runtime resolves an
/// accepted request against its short-lived local resource registry.
public struct L1VisualResourceOffer: Codable, Equatable, Sendable {
    public let resourceID: String
    public let projection: L1VisualProjection
    public let description: String
    public let expiresAt: Date

    public init(
        resourceID: String,
        projection: L1VisualProjection,
        description: String,
        expiresAt: Date
    ) {
        self.resourceID = String(resourceID.prefix(256))
        self.projection = projection
        self.description = String(description.prefix(512))
        self.expiresAt = expiresAt
    }
}

/// Scalar spatial context that helps L1 reason about the current place and
/// coverage without automatically disclosing a camera image or panorama.
public struct L1SpatialContext: Codable, Equatable, Sendable {
    public let panoramaAvailable: Bool
    public let panoramaRevision: UInt64?
    public let reachableCoverageFraction: Double
    public let reachableQualityCoverageFraction: Double
    public let placeRevisits: UInt64
    public let activeSceneEntityCount: Int

    public init(
        panoramaAvailable: Bool,
        panoramaRevision: UInt64? = nil,
        reachableCoverageFraction: Double = 0,
        reachableQualityCoverageFraction: Double = 0,
        placeRevisits: UInt64 = 0,
        activeSceneEntityCount: Int = 0
    ) {
        self.panoramaAvailable = panoramaAvailable
        self.panoramaRevision = panoramaRevision
        self.reachableCoverageFraction = Self.unit(reachableCoverageFraction)
        self.reachableQualityCoverageFraction = Self.unit(reachableQualityCoverageFraction)
        self.placeRevisits = placeRevisits
        self.activeSceneEntityCount = min(max(activeSceneEntityCount, 0), 256)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// A compact public-world observation collected at most once for a local
/// calendar day. It is intentionally independent of any person identity;
/// L1 performs the local relevance judgment from a person's stored context.
public struct L1DailyWorldTopic: Codable, Equatable, Sendable {
    public let title: String
    public let summary: String
    public let sourceURL: String
    public let tags: [String]

    public init(title: String, summary: String, sourceURL: String, tags: [String]) {
        self.title = Self.bounded(title.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 120)
        self.summary = Self.bounded(summary.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 280)
        self.sourceURL = Self.bounded(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 384)
        self.tags = Array(tags.prefix(4)).map {
            Self.bounded($0.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 32)
        }.filter { !$0.isEmpty }
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, bytes))
        for character in value {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}

public struct L1DailyWorldMemory: Codable, Equatable, Sendable {
    public let localDay: String
    public let collectedAt: Date
    public let topics: [L1DailyWorldTopic]

    public init(localDay: String, collectedAt: Date, topics: [L1DailyWorldTopic]) {
        self.localDay = String(localDay.prefix(16))
        self.collectedAt = collectedAt
        self.topics = Array(topics.prefix(3)).filter {
            !$0.title.isEmpty && !$0.summary.isEmpty && URL(string: $0.sourceURL)?.scheme == "https"
        }
    }
}

/// A compact, per-person social-event history. It deliberately records the
/// shape and timing of contact, not transcript text or biometric data. Raw
/// turns remain in the local encrypted conversation journal.
public enum L1SocialContactKind: String, Codable, Equatable, Sendable {
    case nonverbalInvitation = "nonverbal_invitation"
    case proactiveOpening = "proactive_opening"
    case conversationOpened = "conversation_opened"
    case participantResponded = "participant_responded"
    case conversationEnded = "conversation_ended"
    case conversationEndedWithoutParticipantTurn = "conversation_ended_without_participant_turn"
    case conversationInterrupted = "conversation_interrupted"
}

/// Local lifecycle state for one voice-contact episode. It deliberately
/// records only observable turn and transport facts; interpreting intent or
/// refusal remains an L1 memory-consolidation task.
public struct L1ConversationContactEpisode: Equatable, Sendable {
    public private(set) var participantResponded: Bool

    public init(participantResponded: Bool = false) {
        self.participantResponded = participantResponded
    }

    /// Returns true exactly once, for the first finalized participant turn.
    @discardableResult
    public mutating func observeFinalizedTurn(role: ConversationParticipantRole) -> Bool {
        guard role == .user, !participantResponded else { return false }
        participantResponded = true
        return true
    }

    public func closureKind(interrupted: Bool) -> L1SocialContactKind {
        if interrupted { return .conversationInterrupted }
        return participantResponded ? .conversationEnded : .conversationEndedWithoutParticipantTurn
    }
}

public struct L1SocialContactEvent: Codable, Equatable, Sendable {
    public let kind: L1SocialContactKind
    public let occurredAt: Date
    public let purpose: String?

    public init(kind: L1SocialContactKind, occurredAt: Date, purpose: String? = nil) {
        self.kind = kind
        self.occurredAt = occurredAt
        let normalized = purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.purpose = normalized.isEmpty ? nil : String(normalized.prefix(320))
    }
}

public struct L1ConversationContext: Codable, Equatable, Sendable {
    public let turnRecordID: UUID
    public let role: ConversationParticipantRole
    public let rawText: String

    public init(turnRecordID: UUID, role: ConversationParticipantRole, rawText: String) {
        self.turnRecordID = turnRecordID
        self.role = role
        self.rawText = rawText
    }
}

public enum L1InformationMotiveSource: String, Codable, Equatable, Sendable {
    case retainedMemoryGap = "retained_memory_gap"
    case initialSocialOrientation = "initial_social_orientation"
    case interestDiscovery = "interest_discovery"
}

/// An information motive for a recognized person. The goal is not a script:
/// L1 may express it as a natural question, small talk, or not raise it at all
/// after considering the current situation and rapport. Some motives are
/// retained memory gaps; a first meeting can also create a provisional motive
/// to establish how the person wishes to engage.
public struct L1InformationNeed: Codable, Equatable, Sendable {
    public let motiveID: UUID
    public let source: L1InformationMotiveSource
    public let informationGoal: String
    public let expectedInformationGain: Double

    public init(
        motiveID: UUID,
        source: L1InformationMotiveSource,
        informationGoal: String,
        expectedInformationGain: Double
    ) {
        self.motiveID = motiveID
        self.source = source
        self.informationGoal = String(informationGoal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
        self.expectedInformationGain = expectedInformationGain.isFinite
            ? min(max(expectedInformationGain, 0), 1)
            : 0
    }
}

/// Social calibration supplied only from a memory record that permits remote
/// summarization. It is an L1 style/context signal, never an authorization to
/// interrupt someone or control L0 directly.
public struct L1RapportContext: Codable, Equatable, Sendable {
    public let familiarity: Double
    public let interactionComfort: Double
    public let communicationAlignment: Double
    public let proactiveContact: ProactiveContactPreference

    public init(
        familiarity: Double,
        interactionComfort: Double,
        communicationAlignment: Double,
        proactiveContact: ProactiveContactPreference
    ) {
        self.familiarity = Self.unit(familiarity)
        self.interactionComfort = Self.unit(interactionComfort)
        self.communicationAlignment = Self.unit(communicationAlignment)
        self.proactiveContact = proactiveContact
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Bounded L1 working state for one continuing social situation. It carries
/// calibrated pressures and a short model-authored hypothesis, never raw media
/// or conversation text. New evidence is authoritative over this prior state.
public struct L1ThoughtState: Codable, Equatable, Sendable {
    public let socialAvailability: Double
    public let curiosityPressure: Double
    public let interruptionCost: Double
    public let relationshipUncertainty: Double
    public let activeMotiveIDs: [UUID]
    public let workingHypothesis: String
    /// A natural-language inner monologue — the stream of consciousness. This
    /// is the associative, first-person thinking carried forward across cycles
    /// so L1 reasons continuously like a human rather than as stateless snapshots.
    public let streamOfConsciousness: String

    public init(
        socialAvailability: Double,
        curiosityPressure: Double,
        interruptionCost: Double,
        relationshipUncertainty: Double,
        activeMotiveIDs: [UUID],
        workingHypothesis: String,
        streamOfConsciousness: String = ""
    ) {
        self.socialAvailability = Self.unit(socialAvailability)
        self.curiosityPressure = Self.unit(curiosityPressure)
        self.interruptionCost = Self.unit(interruptionCost)
        self.relationshipUncertainty = Self.unit(relationshipUncertainty)
        self.activeMotiveIDs = Array(activeMotiveIDs.prefix(16))
        self.workingHypothesis = String(
            workingHypothesis.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512)
        )
        self.streamOfConsciousness = String(
            streamOfConsciousness.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)
        )
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Current L0 behavioral state fed to the periodic L1 situation-awareness pass.
/// The social-opportunity gate never sees this, so L1 would otherwise be blind
/// to low-level attention/scan behavior such as a prolonged fixation on a
/// non-social target.
public struct L1BehaviorContext: Codable, Equatable, Sendable {
    public let attentionState: String
    public let targetLabel: String?
    public let targetConfidence: Double
    public let isFaceTarget: Bool
    public let fixationSeconds: Double
    public let scanActive: Bool
    public let idleSeconds: Double
    public let recentStates: [String]
    /// The currently recognized identity (e.g. the administrator's name) so the
    /// behavior-awareness pass knows who it is looking at, not just that it is
    /// looking at a face.
    public let recognizedIdentity: String?
    /// Whether a greeting acknowledgment is still pending for the perceived
    /// person. L1 should recommend acknowledge_person only while this is true;
    /// once delivered (false) a repeated directive would be a silent no-op.
    public let acknowledgmentPending: Bool?

    public init(
        attentionState: String,
        targetLabel: String?,
        targetConfidence: Double,
        isFaceTarget: Bool,
        fixationSeconds: Double,
        scanActive: Bool,
        idleSeconds: Double,
        recentStates: [String],
        recognizedIdentity: String? = nil,
        acknowledgmentPending: Bool? = nil
    ) {
        self.attentionState = attentionState
        self.targetLabel = targetLabel.map { String($0.prefix(96)) }
        self.targetConfidence = targetConfidence.isFinite ? min(max(targetConfidence, 0), 1) : 0
        self.isFaceTarget = isFaceTarget
        self.fixationSeconds = fixationSeconds.isFinite ? max(fixationSeconds, 0) : 0
        self.scanActive = scanActive
        self.idleSeconds = idleSeconds.isFinite ? max(idleSeconds, 0) : 0
        self.recentStates = Array(recentStates.prefix(16))
        self.recognizedIdentity = recognizedIdentity.map { String($0.prefix(96)) }
        self.acknowledgmentPending = acknowledgmentPending
    }
}

/// A behavioral directive L1 issues from the periodic situation-awareness pass,
/// independent of any social decision. L0 applies it to attention/scanning.
public enum L1BehaviorAction: String, Codable, Equatable, Sendable {
    case keepObserving = "keep_observing"
    case resumeScanning = "resume_scanning"
    case seekPeople = "seek_people"
    case acknowledgePerson = "acknowledge_person"
    case none
}

public struct L1BehaviorDirective: Codable, Equatable, Sendable {
    public let action: L1BehaviorAction
    public let rationale: String

    public init(action: L1BehaviorAction, rationale: String) {
        self.action = action
        self.rationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
    }
}

public struct L1SituationRequest: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let observedAt: Date
    public let evidenceIDs: [String]
    public let beliefSummary: String
    public let presentEntityIDs: [UUID]
    public let memory: [RemoteMemoryProjection]
    public let informationNeeds: [L1InformationNeed]
    public let rapport: L1RapportContext?
    public let preferredLanguageTag: String?
    public let priorThoughtState: L1ThoughtState?
    public let priorFrame: L1PriorFrame?
    public let recentConversation: [L1ConversationContext]
    public let contactHistory: [L1SocialContactEvent]
    public let spatialContext: L1SpatialContext?
    public let dailyWorldMemory: L1DailyWorldMemory?
    public let visualResourceOffers: [L1VisualResourceOffer]
    public let visuals: [L1VisualResource]
    public let socialOpportunity: L1SocialOpportunity?
    public let behaviorContext: L1BehaviorContext?
    /// Collected web material on curiosity topics, surfaced so L1 can craft a
    /// more grounded, topical conversation opener.
    public let curiosityContext: String?
    /// Explicit per-person preference directives (speech register, address form,
    /// etc.) that L1 must honor in how it engages this person.
    public let personPreferences: String?
    /// How readily L1 opens a spoken conversation despite the person appearing
    /// busy/focused. 0 = conservative, 1 = talkative.
    public let spokenOpeningTendency: Double
    /// Semantically recalled past episodes (narrative summaries) relevant to
    /// the current situation, so L1 can reference shared history.
    public let recalledEpisodes: [String]
    /// How old (seconds) the visual perception in this request is at the time
    /// the request is submitted. Perception (frame capture + on-device
    /// interpretation) happens before cloud reasoning, so L1 must know the gap
    /// to avoid describing stale observations as happening "now".
    public let perceptionAgeSeconds: Double
    /// How long ago (seconds) L1's previous reasoning cycle ran. The
    /// prior_thought_state and prior_frame are that old, not current; without
    /// this L1 treats its own last description as "just now" even when the
    /// cadence gap is minutes.
    public let priorCycleAgeSeconds: Double

    public init(
        cycleID: UUID = UUID(),
        observedAt: Date,
        evidenceIDs: [String],
        beliefSummary: String,
        presentEntityIDs: [UUID] = [],
        memory: [RemoteMemoryProjection] = [],
        informationNeeds: [L1InformationNeed] = [],
        rapport: L1RapportContext? = nil,
        preferredLanguageTag: String? = nil,
        priorThoughtState: L1ThoughtState? = nil,
        priorFrame: L1PriorFrame? = nil,
        recentConversation: [L1ConversationContext] = [],
        contactHistory: [L1SocialContactEvent] = [],
        spatialContext: L1SpatialContext? = nil,
        dailyWorldMemory: L1DailyWorldMemory? = nil,
        visualResourceOffers: [L1VisualResourceOffer] = [],
        visuals: [L1VisualResource] = [],
        socialOpportunity: L1SocialOpportunity? = nil,
        behaviorContext: L1BehaviorContext? = nil,
        curiosityContext: String? = nil,
        personPreferences: String? = nil,
        spokenOpeningTendency: Double = 0.5,
        recalledEpisodes: [String] = [],
        perceptionAgeSeconds: Double = 0,
        priorCycleAgeSeconds: Double = 0
    ) {
        self.cycleID = cycleID
        self.observedAt = observedAt
        self.evidenceIDs = Array(evidenceIDs.prefix(256)).map { String($0.prefix(256)) }
        self.beliefSummary = String(beliefSummary.prefix(8_192))
        self.presentEntityIDs = Array(presentEntityIDs.prefix(128))
        self.memory = Array(memory.prefix(128))
        self.informationNeeds = Array(informationNeeds.prefix(32))
        self.rapport = rapport
        self.preferredLanguageTag = preferredLanguageTag.map { String($0.prefix(35)) }
        self.priorThoughtState = priorThoughtState
        self.priorFrame = priorFrame
        self.recentConversation = Array(recentConversation.prefix(128))
        self.contactHistory = Array(contactHistory.sorted { $0.occurredAt > $1.occurredAt }.prefix(16))
        self.spatialContext = spatialContext
        self.dailyWorldMemory = dailyWorldMemory
        self.visualResourceOffers = Array(visualResourceOffers.prefix(8))
        self.visuals = Array(visuals.prefix(8))
        self.socialOpportunity = socialOpportunity
        self.behaviorContext = behaviorContext
        self.curiosityContext = curiosityContext.map { String($0.prefix(2_000)) }
        self.personPreferences = personPreferences.map { String($0.prefix(1_500)) }
        self.spokenOpeningTendency = min(max(spokenOpeningTendency, 0), 1)
        self.recalledEpisodes = Array(recalledEpisodes.prefix(8)).map { String($0.prefix(1_200)) }
        self.perceptionAgeSeconds = max(perceptionAgeSeconds, 0)
        self.priorCycleAgeSeconds = max(priorCycleAgeSeconds, 0)
    }

    public func continuing(with visuals: [L1VisualResource]) -> Self {
        Self(
            cycleID: cycleID,
            observedAt: observedAt,
            evidenceIDs: evidenceIDs,
            beliefSummary: beliefSummary,
            presentEntityIDs: presentEntityIDs,
            memory: memory,
            informationNeeds: informationNeeds,
            rapport: rapport,
            preferredLanguageTag: preferredLanguageTag,
            priorThoughtState: priorThoughtState,
            recentConversation: recentConversation,
            contactHistory: contactHistory,
            spatialContext: spatialContext,
            dailyWorldMemory: dailyWorldMemory,
            visualResourceOffers: visualResourceOffers,
            visuals: visuals,
            socialOpportunity: socialOpportunity,
            curiosityContext: curiosityContext,
            personPreferences: personPreferences,
            spokenOpeningTendency: spokenOpeningTendency,
            recalledEpisodes: recalledEpisodes,
            perceptionAgeSeconds: perceptionAgeSeconds,
            priorCycleAgeSeconds: priorCycleAgeSeconds
        )
    }
}

public enum L1MemoryProposalKind: String, Codable, CaseIterable, Hashable, Sendable {
    case episode
    case personFact = "person_fact"
    case relationship
    case task
    case openQuestion = "open_question"
    case correction
}

public struct L1MemoryProposal: Codable, Equatable, Sendable {
    public let kind: L1MemoryProposalKind
    public let summary: String
    public let confidence: Double
    public let evidenceIDs: [String]
    public let sourceTurnRecordIDs: [UUID]

    public init(
        kind: L1MemoryProposalKind,
        summary: String,
        confidence: Double,
        evidenceIDs: [String],
        sourceTurnRecordIDs: [UUID] = []
    ) {
        self.kind = kind
        self.summary = String(summary.prefix(4_096))
        self.confidence = confidence
        self.evidenceIDs = Array(evidenceIDs.prefix(128)).map { String($0.prefix(256)) }
        self.sourceTurnRecordIDs = Array(sourceTurnRecordIDs.prefix(128))
    }
}

/// Gemma may suggest social or motor intent, but the existing L1 validators
/// and L0 leases remain the execution boundary.
public struct L1SituationFrame: Codable, Equatable, Sendable {
    public let cycleID: UUID
    public let summary: String
    public let uncertainty: Double
    public let evidenceIDs: [String]
    public let socialDecision: L1SocialDecision?
    public let thoughtState: L1ThoughtState?
    public let memoryProposals: [L1MemoryProposal]
    public let requestedVisualResourceIDs: [String]
    public let behaviorDirective: L1BehaviorDirective?

    public init(
        cycleID: UUID,
        summary: String,
        uncertainty: Double,
        evidenceIDs: [String],
        socialDecision: L1SocialDecision? = nil,
        thoughtState: L1ThoughtState? = nil,
        memoryProposals: [L1MemoryProposal] = [],
        requestedVisualResourceIDs: [String] = [],
        behaviorDirective: L1BehaviorDirective? = nil
    ) {
        self.cycleID = cycleID
        self.summary = String(summary.prefix(8_192))
        self.uncertainty = uncertainty
        self.evidenceIDs = Array(evidenceIDs.prefix(256)).map { String($0.prefix(256)) }
        self.socialDecision = socialDecision
        self.thoughtState = thoughtState
        self.memoryProposals = Array(memoryProposals.prefix(128))
        self.requestedVisualResourceIDs = Array(requestedVisualResourceIDs.prefix(8)).map { String($0.prefix(256)) }
        self.behaviorDirective = behaviorDirective
    }
}

public enum L1InferenceError: Error, Equatable, Sendable {
    case unavailable
    case deadlineExceeded
    case invalidResponse([String])
}

/// The decision output of the previous L1 cycle, carried forward so L1 can
/// reason about its own prior conclusion (what it said, why, and how confident)
/// rather than only its prior inner monologue.
public struct L1PriorFrame: Codable, Equatable, Sendable {
    public let summary: String
    public let action: String?
    public let rationale: String?
    public let opening: String?
    public let confidence: Double?

    public init(
        summary: String,
        action: String? = nil,
        rationale: String? = nil,
        opening: String? = nil,
        confidence: Double? = nil
    ) {
        self.summary = String(summary.prefix(2_048))
        self.action = action.map { String($0.prefix(128)) }
        self.rationale = rationale.map { String($0.prefix(1_024)) }
        self.opening = opening.map { String($0.prefix(1_024)) }
        self.confidence = confidence
    }
}

public protocol L1SituationReasoning: Sendable {
    func infer(_ request: L1SituationRequest, workload: L1Workload) async throws -> L1SituationFrame
}

public struct L1SituationFrameValidator: Sendable {
    public init() {}

    public func validate(_ frame: L1SituationFrame, for request: L1SituationRequest) throws {
        var failures: [String] = []
        if frame.cycleID != request.cycleID { failures.append("cycle ID mismatch") }
        if frame.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("summary is required")
        }
        if !frame.uncertainty.isFinite || !(0 ... 1).contains(frame.uncertainty) {
            failures.append("uncertainty must be in 0...1")
        }
        let requestEvidence = Set(request.evidenceIDs)
        if frame.evidenceIDs.isEmpty || !Set(frame.evidenceIDs).isSubset(of: requestEvidence) {
            failures.append("frame evidence must reference request evidence")
        }
        let turnIDs = Set(request.recentConversation.map(\.turnRecordID))
        for proposal in frame.memoryProposals {
            if proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("memory proposal summary is required")
            }
            if !proposal.confidence.isFinite || !(0 ... 1).contains(proposal.confidence) {
                failures.append("memory proposal confidence must be in 0...1")
            }
            if proposal.evidenceIDs.isEmpty || !Set(proposal.evidenceIDs).isSubset(of: requestEvidence) {
                failures.append("memory proposal evidence must reference request evidence")
            }
            if !Set(proposal.sourceTurnRecordIDs).isSubset(of: turnIDs) {
                failures.append("memory proposal references an unavailable conversation turn")
            }
        }
        if let decision = frame.socialDecision {
            if let opportunity = request.socialOpportunity,
               decision.opportunityID == opportunity.id,
               decision.entityID == opportunity.entityID {
                // The decision validator applies the remaining social policy.
            } else {
                failures.append("social decision requires the current opportunity")
            }
        }
        if let thoughtState = frame.thoughtState {
            let values = [
                thoughtState.socialAvailability,
                thoughtState.curiosityPressure,
                thoughtState.interruptionCost,
                thoughtState.relationshipUncertainty,
            ]
            if values.contains(where: { !$0.isFinite || !(0 ... 1).contains($0) }) {
                failures.append("thought state pressures must be in 0...1")
            }
            if thoughtState.workingHypothesis.isEmpty {
                failures.append("thought state hypothesis is required")
            }
            let motiveIDs = Set(request.informationNeeds.map(\.motiveID))
            if !Set(thoughtState.activeMotiveIDs).isSubset(of: motiveIDs) {
                failures.append("thought state references an unavailable motive")
            }
        }
        let offeredVisualIDs = Set(request.visualResourceOffers.map(\.resourceID))
        if !Set(frame.requestedVisualResourceIDs).isSubset(of: offeredVisualIDs) {
            failures.append("visual request references an unavailable resource")
        }
        if !request.visuals.isEmpty, !frame.requestedVisualResourceIDs.isEmpty {
            failures.append("visual follow-up may not request another visual resource")
        }
        if !failures.isEmpty { throw L1InferenceError.invalidResponse(failures) }
    }
}

/// Decodes the deliberately small JSON surface used by the Gemma situation
/// adapter.  Keeping this conversion in Core makes the model-facing schema
/// testable while all network and scheduling work stays outside L0.
public enum L1SituationResponseDecoder {
    private struct Payload: Decodable {
        let summary: String
        let uncertainty: Double
        let evidenceIDs: [String]
        let action: String?
        let confidence: Double?
        let rationale: String?
        let opening: Opening?
        let thoughtState: ThoughtState?
        let requestedVisualResourceIDs: [String]?
        let behaviorDirective: BehaviorDirective?
        let memoryProposals: [MemoryProposal]?

        enum CodingKeys: String, CodingKey {
            case summary
            case uncertainty
            case evidenceIDs = "evidence_ids"
            case action
            case confidence
            case rationale
            case opening
            case thoughtState = "thought_state"
            case requestedVisualResourceIDs = "requested_visual_resource_ids"
            case behaviorDirective = "behavior_directive"
            case memoryProposals = "memory_proposals"
        }
    }

    private struct MemoryProposal: Decodable {
        let kind: L1MemoryProposalKind
        let summary: String
        let confidence: Double?
        let evidenceIDs: [String]?
        let sourceTurnRecordIDs: [UUID]?

        enum CodingKeys: String, CodingKey {
            case kind
            case summary
            case confidence
            case evidenceIDs = "evidence_ids"
            case sourceTurnRecordIDs = "source_turn_record_ids"
        }
    }

    private struct BehaviorDirective: Decodable {
        let action: String?
        let rationale: String?

        enum CodingKeys: String, CodingKey {
            case action
            case rationale
        }
    }

    private struct ThoughtState: Decodable {
        let socialAvailability: Double
        let curiosityPressure: Double
        let interruptionCost: Double
        let relationshipUncertainty: Double
        let activeMotiveIDs: [UUID]
        let workingHypothesis: String
        let streamOfConsciousness: String?

        enum CodingKeys: String, CodingKey {
            case socialAvailability = "social_availability"
            case curiosityPressure = "curiosity_pressure"
            case interruptionCost = "interruption_cost"
            case relationshipUncertainty = "relationship_uncertainty"
            case activeMotiveIDs = "active_motive_ids"
            case workingHypothesis = "working_hypothesis"
            case streamOfConsciousness = "stream_of_consciousness"
        }
    }

    private struct Opening: Decodable {
        let kind: String
        let motiveID: UUID?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case motiveID = "motive_id"
            case text
        }
    }

    public static func decode(
        _ data: Data,
        for request: L1SituationRequest
    ) throws -> L1SituationFrame {
        let payload = try JSONDecoder().decode(Payload.self, from: normalizedJSON(data))
        let thoughtState: L1ThoughtState?
        if let raw = payload.thoughtState {
            let values = [
                raw.socialAvailability,
                raw.curiosityPressure,
                raw.interruptionCost,
                raw.relationshipUncertainty,
            ]
            guard values.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }),
                  raw.workingHypothesis == raw.workingHypothesis.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.workingHypothesis.isEmpty,
                  raw.workingHypothesis.utf8.count <= 512,
                  !raw.workingHypothesis.contains("\n"),
                  (raw.streamOfConsciousness?.utf8.count ?? 0) <= 2_000,
                  Set(raw.activeMotiveIDs).isSubset(of: Set(request.informationNeeds.map(\.motiveID))) else {
                throw L1InferenceError.invalidResponse(["invalid thought state"])
            }
            thoughtState = L1ThoughtState(
                socialAvailability: raw.socialAvailability,
                curiosityPressure: raw.curiosityPressure,
                interruptionCost: raw.interruptionCost,
                relationshipUncertainty: raw.relationshipUncertainty,
                activeMotiveIDs: raw.activeMotiveIDs,
                workingHypothesis: raw.workingHypothesis,
                streamOfConsciousness: raw.streamOfConsciousness ?? ""
            )
        } else {
            thoughtState = nil
        }
        let decision: L1SocialDecision?
        if request.socialOpportunity == nil {
            // Behavior-awareness pass: any social decision the model emits is
            // irrelevant (we only consume behaviorDirective) and must not
            // invalidate the frame.
            decision = nil
        } else if let action = payload.action {
            guard let opportunity = request.socialOpportunity,
                  let socialAction = L1SocialAction(rawValue: action),
                  let confidence = payload.confidence,
                  let rationale = payload.rationale else {
                throw L1InferenceError.invalidResponse(["invalid social decision"])
            }
            let opening: ProactiveOpeningContent?
            switch payload.opening?.kind {
            case nil:
                opening = nil
            case "greeting":
                throw L1InferenceError.invalidResponse(["a spoken opening requires a purpose-grounded question"])
            case "question":
                guard let motiveID = payload.opening?.motiveID,
                      let text = payload.opening?.text,
                      request.informationNeeds.contains(where: { $0.motiveID == motiveID }),
                      isNaturalOpening(text) else {
                    throw L1InferenceError.invalidResponse(["invalid question opening"])
                }
                opening = .question(motiveID: motiveID, text: text)
            default:
                throw L1InferenceError.invalidResponse(["unknown opening kind"])
            }
            decision = L1SocialDecision(
                opportunityID: opportunity.id,
                entityID: opportunity.entityID,
                action: socialAction,
                confidence: confidence,
                rationale: rationale,
                evidenceIDs: payload.evidenceIDs,
                openingContent: opening
            )
        } else {
            guard payload.opening == nil,
                  payload.confidence == nil,
                  payload.rationale == nil else {
                throw L1InferenceError.invalidResponse(["social fields require an action"])
            }
            decision = nil
        }
        let behaviorDirective: L1BehaviorDirective?
        if let raw = payload.behaviorDirective,
           let actionRaw = raw.action,
           let action = L1BehaviorAction(rawValue: actionRaw),
           action != .none {
            behaviorDirective = L1BehaviorDirective(
                action: action,
                rationale: raw.rationale ?? ""
            )
        } else {
            behaviorDirective = nil
        }
        let memoryProposals: [L1MemoryProposal] = (payload.memoryProposals ?? []).compactMap { raw in
            guard let confidence = raw.confidence, confidence.isFinite else { return nil }
            return L1MemoryProposal(
                kind: raw.kind,
                summary: raw.summary,
                confidence: confidence,
                evidenceIDs: raw.evidenceIDs ?? [],
                sourceTurnRecordIDs: raw.sourceTurnRecordIDs ?? []
            )
        }
        let frame = L1SituationFrame(
            cycleID: request.cycleID,
            summary: payload.summary,
            uncertainty: payload.uncertainty,
            evidenceIDs: payload.evidenceIDs,
            socialDecision: decision,
            thoughtState: thoughtState,
            memoryProposals: memoryProposals,
            requestedVisualResourceIDs: payload.requestedVisualResourceIDs ?? [],
            behaviorDirective: behaviorDirective
        )
        try L1SituationFrameValidator().validate(frame, for: request)
        return frame
    }

    private static func normalizedJSON(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```"),
              let firstNewline = text.firstIndex(of: "\n"),
              text.hasSuffix("```") else {
            return data
        }
        let contentStart = text.index(after: firstNewline)
        let contentEnd = text.index(text.endIndex, offsetBy: -3)
        return Data(text[contentStart..<contentEnd].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    private static func isNaturalOpening(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == text,
              !normalized.isEmpty,
              normalized.utf8.count <= 320,
              !normalized.contains("\n") else {
            return false
        }
        return true
    }
}
