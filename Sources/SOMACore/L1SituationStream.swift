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
        spokenOpeningTendency: Double = 0.7
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
    /// This describes when the camera observed the view, not when the backing
    /// file was atomically written.
    public let capturedAt: Date?

    public init(
        resourceID: String,
        projection: L1VisualProjection,
        localPath: String,
        expiresAt: Date,
        capturedAt: Date? = nil
    ) {
        self.resourceID = String(resourceID.prefix(256))
        self.projection = projection
        self.localPath = localPath
        self.expiresAt = expiresAt
        self.capturedAt = capturedAt
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

/// The stable, local identifier of the place currently surrounding SOMA. It
/// is deliberately a relationship *question*, not an attribution: observations
/// stay attached to this place until a person explicitly establishes their
/// affiliation with it.
public struct L1PlaceAffiliationContext: Codable, Equatable, Sendable {
    public let spaceID: UUID
    public let label: String?
    public let isStable: Bool
    public let ownerEntityID: UUID?
    public let unassignedObservationCount: Int

    public init(
        spaceID: UUID,
        label: String? = nil,
        isStable: Bool,
        ownerEntityID: UUID? = nil,
        unassignedObservationCount: Int = 0
    ) {
        self.spaceID = spaceID
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = normalized.isEmpty ? nil : String(normalized.prefix(64))
        self.isStable = isStable
        self.ownerEntityID = ownerEntityID
        self.unassignedObservationCount = min(max(unassignedObservationCount, 0), 200)
    }

    /// A stable place with no known affiliation is a durable situational gap.
    /// It becomes a social motive only when L1 is considering a person; it is
    /// never itself an instruction to interrupt or to attribute objects.
    public var affiliationUnresolved: Bool {
        isStable && ownerEntityID == nil
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
    public let placeAffiliation: L1PlaceAffiliationContext?

    public init(
        panoramaAvailable: Bool,
        panoramaRevision: UInt64? = nil,
        reachableCoverageFraction: Double = 0,
        reachableQualityCoverageFraction: Double = 0,
        placeRevisits: UInt64 = 0,
        activeSceneEntityCount: Int = 0,
        placeAffiliation: L1PlaceAffiliationContext? = nil
    ) {
        self.panoramaAvailable = panoramaAvailable
        self.panoramaRevision = panoramaRevision
        self.reachableCoverageFraction = Self.unit(reachableCoverageFraction)
        self.reachableQualityCoverageFraction = Self.unit(reachableQualityCoverageFraction)
        self.placeRevisits = placeRevisits
        self.activeSceneEntityCount = min(max(activeSceneEntityCount, 0), 256)
        self.placeAffiliation = placeAffiliation
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

/// Derives the mutable part of rapport from observed reciprocal contact.  It
/// intentionally excludes inferred personality or sentiment: a reply and a
/// completed conversation are evidence of conversational continuity, while a
/// missed opening is only weak evidence of lower availability.
public enum L1SocialRapportEstimator {
    public static func infer(
        from events: [L1SocialContactEvent],
        at date: Date = Date()
    ) -> RapportProfile? {
        guard !events.isEmpty else { return nil }

        var familiarityEvidence = 0.0
        var positiveExchangeEvidence = 0.0
        var unansweredOpeningEvidence = 0.0
        var alignmentEvidence = 0.0
        var misalignmentEvidence = 0.0

        for event in events {
            let age = max(0, date.timeIntervalSince(event.occurredAt))
            let recency = exp(-age / (45 * 24 * 60 * 60))
            switch event.kind {
            case .nonverbalInvitation:
                break
            case .proactiveOpening:
                break
            case .conversationOpened:
                break
            case .participantResponded:
                familiarityEvidence += 0.35 * recency
                positiveExchangeEvidence += 1.0 * recency
                alignmentEvidence += 1.0 * recency
            case .conversationEnded:
                familiarityEvidence += 0.10 * recency
                positiveExchangeEvidence += 0.30 * recency
                alignmentEvidence += 0.35 * recency
            case .conversationEndedWithoutParticipantTurn:
                unansweredOpeningEvidence += 0.55 * recency
                misalignmentEvidence += 0.30 * recency
            case .conversationInterrupted:
                // A transport or environmental interruption is not a social
                // rejection, so it adds no negative relationship evidence.
                break
            }
        }

        let familiarity = familiarityEvidence / (familiarityEvidence + 1.5)
        let interactionComfort = (1 + positiveExchangeEvidence)
            / (2 + positiveExchangeEvidence + unansweredOpeningEvidence)
        let communicationAlignment = (1 + alignmentEvidence)
            / (2 + alignmentEvidence + misalignmentEvidence)
        return RapportProfile(
            familiarity: Self.unit(familiarity),
            interactionComfort: Self.unit(interactionComfort),
            communicationAlignment: Self.unit(communicationAlignment),
            proactiveContact: .unknown
        )
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, 0), 1)
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
    case placeAffiliation = "place_affiliation"
    case conversationFollowUp = "conversation_follow_up"

    /// Whether the authoritative materialized person profile already contains
    /// the fact this canonical acquisition motive exists to learn. Event
    /// recency windows must not participate in this decision.
    public func isSatisfied(by context: PersonContextSnapshot) -> Bool {
        switch self {
        case .initialSocialOrientation:
            context.mission.isSatisfied
        case .interestDiscovery:
            !Set([
                "interest_profile",
                "interests",
                "favorite_topics",
                "hobbies",
            ]).isDisjoint(with: Set(context.facts.keys))
        case .retainedMemoryGap, .placeAffiliation, .conversationFollowUp:
            false
        }
    }
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

    /// A retained uncertainty may guide L1's private reasoning or an ongoing
    /// conversation, but only needs grounded in a canonical social goal or a
    /// prior participant conversation may initiate speech from silence.
    public var permitsProactiveSpokenOpening: Bool {
        switch source {
        case .initialSocialOrientation, .interestDiscovery, .conversationFollowUp:
            true
        case .retainedMemoryGap, .placeAffiliation:
            false
        }
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

/// A bounded L0 summary of directed visual contact. It describes temporal
/// interaction evidence rather than a single frame, so L1 can distinguish a
/// passing glance from sustained or repeated attention without receiving gaze
/// landmarks or video data.
public struct L1ContactPattern: Codable, Equatable, Sendable {
    public let eyeContactActive: Bool
    public let recentEpisodeCount: Int
    public let latestEpisodeAgeSeconds: Double?
    public let activeDurationSeconds: Double

    public init(
        eyeContactActive: Bool,
        recentEpisodeCount: Int,
        latestEpisodeAgeSeconds: Double?,
        activeDurationSeconds: Double
    ) {
        self.eyeContactActive = eyeContactActive
        self.recentEpisodeCount = min(max(recentEpisodeCount, 0), 32)
        self.latestEpisodeAgeSeconds = latestEpisodeAgeSeconds.map { max($0, 0) }
        self.activeDurationSeconds = max(activeDurationSeconds, 0)
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
