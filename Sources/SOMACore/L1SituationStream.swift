import Foundation

public enum L1Workload: String, Codable, CaseIterable, Hashable, Sendable {
    case situation
    case memoryConsolidation = "memory_consolidation"
}

public struct L1ModelConfiguration: Codable, Equatable, Sendable {
    public let model: String
    public let situationDeadlineMilliseconds: UInt64
    public let consolidationDeadlineMilliseconds: UInt64

    public init(
        situationDeadlineMilliseconds: UInt64 = 8_000,
        consolidationDeadlineMilliseconds: UInt64 = 60_000
    ) {
        precondition(situationDeadlineMilliseconds > 0)
        precondition(consolidationDeadlineMilliseconds >= situationDeadlineMilliseconds)
        self.model = "gemma4:31b-cloud"
        self.situationDeadlineMilliseconds = situationDeadlineMilliseconds
        self.consolidationDeadlineMilliseconds = consolidationDeadlineMilliseconds
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

    public init(
        socialAvailability: Double,
        curiosityPressure: Double,
        interruptionCost: Double,
        relationshipUncertainty: Double,
        activeMotiveIDs: [UUID],
        workingHypothesis: String
    ) {
        self.socialAvailability = Self.unit(socialAvailability)
        self.curiosityPressure = Self.unit(curiosityPressure)
        self.interruptionCost = Self.unit(interruptionCost)
        self.relationshipUncertainty = Self.unit(relationshipUncertainty)
        self.activeMotiveIDs = Array(activeMotiveIDs.prefix(16))
        self.workingHypothesis = String(
            workingHypothesis.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512)
        )
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
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
    public let recentConversation: [L1ConversationContext]
    public let visuals: [L1VisualResource]
    public let socialOpportunity: L1SocialOpportunity?

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
        recentConversation: [L1ConversationContext] = [],
        visuals: [L1VisualResource] = [],
        socialOpportunity: L1SocialOpportunity? = nil
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
        self.recentConversation = Array(recentConversation.prefix(128))
        self.visuals = Array(visuals.prefix(8))
        self.socialOpportunity = socialOpportunity
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

    public init(
        cycleID: UUID,
        summary: String,
        uncertainty: Double,
        evidenceIDs: [String],
        socialDecision: L1SocialDecision? = nil,
        thoughtState: L1ThoughtState? = nil,
        memoryProposals: [L1MemoryProposal] = [],
        requestedVisualResourceIDs: [String] = []
    ) {
        self.cycleID = cycleID
        self.summary = String(summary.prefix(8_192))
        self.uncertainty = uncertainty
        self.evidenceIDs = Array(evidenceIDs.prefix(256)).map { String($0.prefix(256)) }
        self.socialDecision = socialDecision
        self.thoughtState = thoughtState
        self.memoryProposals = Array(memoryProposals.prefix(128))
        self.requestedVisualResourceIDs = Array(requestedVisualResourceIDs.prefix(8)).map { String($0.prefix(256)) }
    }
}

public enum L1InferenceError: Error, Equatable, Sendable {
    case unavailable
    case deadlineExceeded
    case invalidResponse([String])
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

        enum CodingKeys: String, CodingKey {
            case summary
            case uncertainty
            case evidenceIDs = "evidence_ids"
            case action
            case confidence
            case rationale
            case opening
            case thoughtState = "thought_state"
        }
    }

    private struct ThoughtState: Decodable {
        let socialAvailability: Double
        let curiosityPressure: Double
        let interruptionCost: Double
        let relationshipUncertainty: Double
        let activeMotiveIDs: [UUID]
        let workingHypothesis: String

        enum CodingKeys: String, CodingKey {
            case socialAvailability = "social_availability"
            case curiosityPressure = "curiosity_pressure"
            case interruptionCost = "interruption_cost"
            case relationshipUncertainty = "relationship_uncertainty"
            case activeMotiveIDs = "active_motive_ids"
            case workingHypothesis = "working_hypothesis"
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
                  Set(raw.activeMotiveIDs).isSubset(of: Set(request.informationNeeds.map(\.motiveID))) else {
                throw L1InferenceError.invalidResponse(["invalid thought state"])
            }
            thoughtState = L1ThoughtState(
                socialAvailability: raw.socialAvailability,
                curiosityPressure: raw.curiosityPressure,
                interruptionCost: raw.interruptionCost,
                relationshipUncertainty: raw.relationshipUncertainty,
                activeMotiveIDs: raw.activeMotiveIDs,
                workingHypothesis: raw.workingHypothesis
            )
        } else {
            thoughtState = nil
        }
        let decision: L1SocialDecision?
        if let action = payload.action {
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
        let frame = L1SituationFrame(
            cycleID: request.cycleID,
            summary: payload.summary,
            uncertainty: payload.uncertainty,
            evidenceIDs: payload.evidenceIDs,
            socialDecision: decision,
            thoughtState: thoughtState
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
