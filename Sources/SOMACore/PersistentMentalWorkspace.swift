import CryptoKit
import Foundation

public enum MentalEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ordinaryObservation = "ordinary_observation"
    case personArrived = "person_arrived"
    case personDeparted = "person_departed"
    case directSocialBid = "direct_social_bid"
    case objectPresentation = "object_presentation"
    case sceneTransition = "scene_transition"
    case memoryAssociation = "memory_association"
    case conversationOutcome = "conversation_outcome"
    case elapsedTime = "elapsed_time"

    public var demandsImmediateReflection: Bool {
        switch self {
        case .personArrived, .personDeparted, .directSocialBid,
             .objectPresentation, .sceneTransition, .conversationOutcome:
            true
        case .ordinaryObservation, .memoryAssociation, .elapsedTime:
            false
        }
    }
}

public enum MentalHypothesisKind: String, Codable, CaseIterable, Hashable, Sendable {
    case perceptual
    case situational
    case social
    case memoryAssociation = "memory_association"
    case curiosity
}

public enum MentalHypothesisStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case dormant
    case abandoned
    case resolved
}

public struct MentalHypothesisSeed: Codable, Equatable, Sendable {
    public let id: UUID?
    public let kind: MentalHypothesisKind
    public let subjectEntityID: UUID?
    public let content: String
    public let confidence: Double
    public let salience: Double

    public init(
        id: UUID? = nil,
        kind: MentalHypothesisKind,
        subjectEntityID: UUID? = nil,
        content: String,
        confidence: Double,
        salience: Double
    ) {
        self.id = id
        self.kind = kind
        self.subjectEntityID = subjectEntityID
        self.content = Self.bounded(content, maximum: 1_024)
        self.confidence = Self.unit(confidence)
        self.salience = Self.unit(salience)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }
}

public struct MentalHypothesis: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: MentalHypothesisKind
    public let subjectEntityID: UUID?
    public let content: String
    public let confidence: Double
    public let salience: Double
    public let createdAt: Date
    public let lastSupportedAt: Date
    public let lastContradictedAt: Date?
    public let evidenceIDs: [String]
    public let status: MentalHypothesisStatus

    public init(
        id: UUID,
        kind: MentalHypothesisKind,
        subjectEntityID: UUID? = nil,
        content: String,
        confidence: Double,
        salience: Double,
        createdAt: Date,
        lastSupportedAt: Date,
        lastContradictedAt: Date? = nil,
        evidenceIDs: [String],
        status: MentalHypothesisStatus
    ) {
        self.id = id
        self.kind = kind
        self.subjectEntityID = subjectEntityID
        self.content = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
        self.confidence = Self.unit(confidence)
        self.salience = Self.unit(salience)
        self.createdAt = createdAt
        self.lastSupportedAt = lastSupportedAt
        self.lastContradictedAt = lastContradictedAt
        self.evidenceIDs = Array(evidenceIDs.uniqued().suffix(32)).map { String($0.prefix(256)) }
        self.status = status
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct MentalDriveState: Codable, Equatable, Sendable {
    public let curiosity: Double
    public let concern: Double
    public let boredom: Double
    public let socialInterest: Double
    public let interruptionPressure: Double

    public init(
        curiosity: Double = 0,
        concern: Double = 0,
        boredom: Double = 0,
        socialInterest: Double = 0,
        interruptionPressure: Double = 0
    ) {
        self.curiosity = Self.unit(curiosity)
        self.concern = Self.unit(concern)
        self.boredom = Self.unit(boredom)
        self.socialInterest = Self.unit(socialInterest)
        self.interruptionPressure = Self.unit(interruptionPressure)
    }

    public func applying(_ signal: MentalDriveSignal, weight: Double) -> Self {
        let w = Self.unit(weight)
        return Self(
            curiosity: curiosity + signal.curiosity * w,
            concern: concern + signal.concern * w,
            boredom: boredom + signal.boredom * w,
            socialInterest: socialInterest + signal.socialInterest * w,
            interruptionPressure: interruptionPressure + signal.interruptionPressure * w
        )
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct MentalDriveSignal: Codable, Equatable, Sendable {
    public let curiosity: Double
    public let concern: Double
    public let boredom: Double
    public let socialInterest: Double
    public let interruptionPressure: Double

    public init(
        curiosity: Double = 0,
        concern: Double = 0,
        boredom: Double = 0,
        socialInterest: Double = 0,
        interruptionPressure: Double = 0
    ) {
        self.curiosity = curiosity.isFinite ? min(max(curiosity, -1), 1) : 0
        self.concern = concern.isFinite ? min(max(concern, -1), 1) : 0
        self.boredom = boredom.isFinite ? min(max(boredom, -1), 1) : 0
        self.socialInterest = socialInterest.isFinite ? min(max(socialInterest, -1), 1) : 0
        self.interruptionPressure = interruptionPressure.isFinite
            ? min(max(interruptionPressure, -1), 1)
            : 0
    }
}

public enum ThoughtChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case perceptual
    case social
    case memoryAssociation = "memory_association"
    case curiosity
    case selfCorrection = "self_correction"
    case idle
}

public enum ThoughtContinuity: String, Codable, CaseIterable, Hashable, Sendable {
    case `continue`
    case revise
    case contradict
    case associate
    case retire
    case idle
}

public struct ThoughtCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let channel: ThoughtChannel
    public let content: String
    public let confidence: Double
    public let salience: Double
    public let novelty: Double
    public let parentThoughtID: UUID?
    public let continuity: ThoughtContinuity
    public let hypothesisIDs: [UUID]
    public let createdAt: Date
    public let lastForegroundAt: Date?

    public init(
        id: UUID = UUID(),
        channel: ThoughtChannel,
        content: String,
        confidence: Double,
        salience: Double,
        novelty: Double,
        parentThoughtID: UUID? = nil,
        continuity: ThoughtContinuity,
        hypothesisIDs: [UUID] = [],
        createdAt: Date = Date(),
        lastForegroundAt: Date? = nil
    ) {
        self.id = id
        self.channel = channel
        self.content = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096))
        self.confidence = Self.unit(confidence)
        self.salience = Self.unit(salience)
        self.novelty = Self.unit(novelty)
        self.parentThoughtID = parentThoughtID
        self.continuity = continuity
        self.hypothesisIDs = Array(hypothesisIDs.uniqued().prefix(16))
        self.createdAt = createdAt
        self.lastForegroundAt = lastForegroundAt
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct MentalContextPatch: Codable, Equatable, Sendable {
    public let presentEntityIDs: [UUID]?
    public let eyeContactActive: Bool?
    public let participantSpeaking: Bool?
    public let conversationActive: Bool?
    public let socialAvailability: Double?
    public let relationshipUncertainty: Double?

    public init(
        presentEntityIDs: [UUID]? = nil,
        eyeContactActive: Bool? = nil,
        participantSpeaking: Bool? = nil,
        conversationActive: Bool? = nil,
        socialAvailability: Double? = nil,
        relationshipUncertainty: Double? = nil
    ) {
        self.presentEntityIDs = presentEntityIDs.map { Array($0.uniqued().prefix(16)) }
        self.eyeContactActive = eyeContactActive
        self.participantSpeaking = participantSpeaking
        self.conversationActive = conversationActive
        self.socialAvailability = socialAvailability.map(Self.unit)
        self.relationshipUncertainty = relationshipUncertainty.map(Self.unit)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct MentalContextState: Codable, Equatable, Sendable {
    public let presentEntityIDs: [UUID]
    public let eyeContactActive: Bool
    public let participantSpeaking: Bool
    public let conversationActive: Bool
    public let socialAvailability: Double
    public let relationshipUncertainty: Double
    public let updatedAt: Date
    public let evidenceIDs: [String]

    public init(
        presentEntityIDs: [UUID] = [],
        eyeContactActive: Bool = false,
        participantSpeaking: Bool = false,
        conversationActive: Bool = false,
        socialAvailability: Double = 0,
        relationshipUncertainty: Double = 1,
        updatedAt: Date = .distantPast,
        evidenceIDs: [String] = []
    ) {
        self.presentEntityIDs = Array(presentEntityIDs.uniqued().prefix(16))
        self.eyeContactActive = eyeContactActive
        self.participantSpeaking = participantSpeaking
        self.conversationActive = conversationActive
        self.socialAvailability = Self.unit(socialAvailability)
        self.relationshipUncertainty = Self.unit(relationshipUncertainty)
        self.updatedAt = updatedAt
        self.evidenceIDs = Array(evidenceIDs.uniqued().suffix(32)).map { String($0.prefix(256)) }
    }

    public static func staleRestored(at date: Date, relationshipUncertainty: Double) -> Self {
        Self(relationshipUncertainty: relationshipUncertainty, updatedAt: date)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct MentalEvidenceEvent: Codable, Equatable, Sendable {
    public let id: String
    public let observedAt: Date
    public let kind: MentalEvidenceKind
    public let summary: String
    public let subjectEntityID: UUID?
    public let confidence: Double
    public let novelty: Double
    public let contextPatch: MentalContextPatch?
    public let hypothesis: MentalHypothesisSeed?
    public let driveSignal: MentalDriveSignal

    public init(
        id: String,
        observedAt: Date = Date(),
        kind: MentalEvidenceKind,
        summary: String,
        subjectEntityID: UUID? = nil,
        confidence: Double,
        novelty: Double,
        contextPatch: MentalContextPatch? = nil,
        hypothesis: MentalHypothesisSeed? = nil,
        driveSignal: MentalDriveSignal = .init()
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        self.observedAt = observedAt
        self.kind = kind
        self.summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_048))
        self.subjectEntityID = subjectEntityID
        self.confidence = Self.unit(confidence)
        self.novelty = Self.unit(novelty)
        self.contextPatch = contextPatch
        self.hypothesis = hypothesis
        self.driveSignal = driveSignal
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public enum MentalHypothesisMutationOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case propose
    case support
    case contradict
    case resolve
    case abandon
}

public struct MentalHypothesisMutation: Codable, Equatable, Sendable {
    public let operation: MentalHypothesisMutationOperation
    public let hypothesisID: UUID?
    public let seed: MentalHypothesisSeed?
    public let strength: Double
    public let evidenceIDs: [String]

    public init(
        operation: MentalHypothesisMutationOperation,
        hypothesisID: UUID? = nil,
        seed: MentalHypothesisSeed? = nil,
        strength: Double,
        evidenceIDs: [String]
    ) {
        self.operation = operation
        self.hypothesisID = hypothesisID
        self.seed = seed
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : 0
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
    }
}

public struct MentalIntention: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let domain: String
    public let objective: String
    public let attentionTargetLabel: String?
    public let pressure: Double
    public let evidenceIDs: [String]
    public let createdAt: Date
    public let executedAt: Date?

    public init(
        id: UUID = UUID(),
        domain: String,
        objective: String,
        attentionTargetLabel: String? = nil,
        pressure: Double,
        evidenceIDs: [String],
        createdAt: Date = Date(),
        executedAt: Date? = nil
    ) {
        self.id = id
        self.domain = String(domain.prefix(64))
        self.objective = String(objective.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
        self.attentionTargetLabel = attentionTargetLabel.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
        }
        self.pressure = pressure.isFinite ? min(max(pressure, 0), 1) : 0
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
        self.createdAt = createdAt
        self.executedAt = executedAt
    }
}

public struct L1ThoughtUpdate: Codable, Equatable, Sendable {
    public let expectedRevision: UInt64
    public let evidenceIDs: [String]
    public let innerMonologue: String
    public let channel: ThoughtChannel
    public let continuity: ThoughtContinuity
    public let parentThoughtID: UUID?
    public let confidence: Double
    public let salience: Double
    public let novelty: Double
    public let hypothesisMutations: [MentalHypothesisMutation]
    public let driveSignal: MentalDriveSignal
    public let intention: MentalIntention?
    public let requestedVisualResourceIDs: [String]
    public let memoryProposals: [L1MemoryProposal]

    public init(
        expectedRevision: UInt64,
        evidenceIDs: [String],
        innerMonologue: String,
        channel: ThoughtChannel,
        continuity: ThoughtContinuity,
        parentThoughtID: UUID? = nil,
        confidence: Double,
        salience: Double,
        novelty: Double,
        hypothesisMutations: [MentalHypothesisMutation] = [],
        driveSignal: MentalDriveSignal = .init(),
        intention: MentalIntention? = nil,
        requestedVisualResourceIDs: [String] = [],
        memoryProposals: [L1MemoryProposal] = []
    ) {
        self.expectedRevision = expectedRevision
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(64)).map { String($0.prefix(256)) }
        self.innerMonologue = String(innerMonologue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096))
        self.channel = channel
        self.continuity = continuity
        self.parentThoughtID = parentThoughtID
        self.confidence = Self.unit(confidence)
        self.salience = Self.unit(salience)
        self.novelty = Self.unit(novelty)
        self.hypothesisMutations = Array(hypothesisMutations.prefix(16))
        self.driveSignal = driveSignal
        self.intention = intention
        self.requestedVisualResourceIDs = Array(requestedVisualResourceIDs.uniqued().prefix(4))
            .map { String($0.prefix(256)) }
        self.memoryProposals = Array(memoryProposals.prefix(32))
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct MentalWorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let revision: UInt64
    public let updatedAt: Date
    public let restoredStale: Bool
    public let context: MentalContextState
    public let hypotheses: [MentalHypothesis]
    public let drives: MentalDriveState
    public let thoughtCandidates: [ThoughtCandidate]
    public let foregroundThoughtID: UUID?
    public let intentions: [MentalIntention]
    public let recentNovelty: Double
    public let lastThoughtAt: Date?
    public let processedEvidenceIDs: [String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64 = 0,
        updatedAt: Date = .distantPast,
        restoredStale: Bool = false,
        context: MentalContextState = .init(),
        hypotheses: [MentalHypothesis] = [],
        drives: MentalDriveState = .init(),
        thoughtCandidates: [ThoughtCandidate] = [],
        foregroundThoughtID: UUID? = nil,
        intentions: [MentalIntention] = [],
        recentNovelty: Double = 0,
        lastThoughtAt: Date? = nil,
        processedEvidenceIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.updatedAt = updatedAt
        self.restoredStale = restoredStale
        self.context = context
        self.hypotheses = Array(hypotheses.prefix(32))
        self.drives = drives
        self.thoughtCandidates = Array(thoughtCandidates.prefix(16))
        self.foregroundThoughtID = foregroundThoughtID
        self.intentions = Array(intentions.prefix(16))
        self.recentNovelty = recentNovelty.isFinite ? min(max(recentNovelty, 0), 1) : 0
        self.lastThoughtAt = lastThoughtAt
        self.processedEvidenceIDs = Array(processedEvidenceIDs.uniqued().suffix(256))
            .map { String($0.prefix(256)) }
    }

    public var foregroundThought: ThoughtCandidate? {
        guard let foregroundThoughtID else { return nil }
        return thoughtCandidates.first { $0.id == foregroundThoughtID }
    }
}

public struct MentalStateDelta: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let beforeRevision: UInt64
    public let afterRevision: UInt64
    public let changedFields: [String]
    public let novelty: Double
    public let meaningfulTransition: Bool
    public let duplicateEvidence: Bool
}

public struct WorkspaceTransition: Codable, Equatable, Sendable {
    public let before: MentalWorkspaceSnapshot
    public let after: MentalWorkspaceSnapshot
    public let delta: MentalStateDelta

    public var changed: Bool { before.revision != after.revision }
}

public struct MentalDynamicsPolicy: Equatable, Sendable {
    public let perceptualHalfLifeSeconds: Double
    public let situationalHalfLifeSeconds: Double
    public let socialHalfLifeSeconds: Double
    public let associationHalfLifeSeconds: Double
    public let curiosityHalfLifeSeconds: Double
    public let dormantConfidence: Double
    public let abandonedConfidence: Double
    public let supportLogOdds: Double
    public let contradictionLogOdds: Double
    public let contextEvidenceWeight: Double
    public let foregroundTemperature: Double
    public let foregroundInertia: Double
    public let quietExpectedThoughtIntervalSeconds: Double

    public init(
        perceptualHalfLifeSeconds: Double = 30,
        situationalHalfLifeSeconds: Double = 300,
        socialHalfLifeSeconds: Double = 90,
        associationHalfLifeSeconds: Double = 900,
        curiosityHalfLifeSeconds: Double = 1_800,
        dormantConfidence: Double = 0.35,
        abandonedConfidence: Double = 0.18,
        supportLogOdds: Double = 0.9,
        contradictionLogOdds: Double = 1.4,
        contextEvidenceWeight: Double = 0.35,
        foregroundTemperature: Double = 0.32,
        foregroundInertia: Double = 0.18,
        quietExpectedThoughtIntervalSeconds: Double = 150
    ) {
        self.perceptualHalfLifeSeconds = max(perceptualHalfLifeSeconds, 1)
        self.situationalHalfLifeSeconds = max(situationalHalfLifeSeconds, 1)
        self.socialHalfLifeSeconds = max(socialHalfLifeSeconds, 1)
        self.associationHalfLifeSeconds = max(associationHalfLifeSeconds, 1)
        self.curiosityHalfLifeSeconds = max(curiosityHalfLifeSeconds, 1)
        self.dormantConfidence = min(max(dormantConfidence, 0), 1)
        self.abandonedConfidence = min(max(abandonedConfidence, 0), self.dormantConfidence)
        self.supportLogOdds = max(supportLogOdds, 0)
        self.contradictionLogOdds = max(contradictionLogOdds, 0)
        self.contextEvidenceWeight = min(max(contextEvidenceWeight, 0), 1)
        self.foregroundTemperature = max(foregroundTemperature, 0.01)
        self.foregroundInertia = max(foregroundInertia, 0)
        self.quietExpectedThoughtIntervalSeconds = max(quietExpectedThoughtIntervalSeconds, 1)
    }

    public func halfLife(for kind: MentalHypothesisKind) -> Double {
        switch kind {
        case .perceptual: perceptualHalfLifeSeconds
        case .situational: situationalHalfLifeSeconds
        case .social: socialHalfLifeSeconds
        case .memoryAssociation: associationHalfLifeSeconds
        case .curiosity: curiosityHalfLifeSeconds
        }
    }
}

public enum PersistentMentalWorkspaceError: Error, Equatable, Sendable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case unknownHypothesis(UUID)
    case unsupportedEvidence(String)
    case invalidThought
    case corruptCheckpoint
}

public actor PersistentMentalWorkspace {
    private var state: MentalWorkspaceSnapshot
    private let policy: MentalDynamicsPolicy
    private var randomState: UInt64

    public init(
        snapshot: MentalWorkspaceSnapshot = .init(),
        policy: MentalDynamicsPolicy = .init(),
        randomSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) {
        state = snapshot
        self.policy = policy
        randomState = randomSeed == 0 ? 0x9E37_79B9_7F4A_7C15 : randomSeed
    }

    public func snapshot(at date: Date = Date()) -> MentalWorkspaceSnapshot {
        advanceDynamics(to: date)
        return state
    }

    /// A non-mutating read for completion-time authority checks. Model latency
    /// must not make its own response stale merely because confidence decay was
    /// sampled while validating that response.
    public func currentSnapshot() -> MentalWorkspaceSnapshot {
        state
    }

    public func ingest(_ event: MentalEvidenceEvent) -> WorkspaceTransition {
        let before = state
        if state.processedEvidenceIDs.contains(event.id) {
            return transition(
                before: before,
                after: state,
                evidenceID: event.id,
                changes: [],
                novelty: 0,
                meaningful: false,
                duplicate: true
            )
        }
        advanceDynamics(to: event.observedAt)
        var changes: [String] = []
        var hypotheses = state.hypotheses
        var context = state.context
        var drives = state.drives
        var semanticTransition = false
        var repeatedActiveHypothesis = false

        if let patch = event.contextPatch {
            let patched = apply(patch, to: context, event: event)
            if patched != context {
                context = patched
                changes.append("context")
                semanticTransition = true
            }
        }

        if let seed = event.hypothesis, !seed.content.isEmpty {
            if let index = hypotheses.firstIndex(where: {
                $0.status != .abandoned && $0.status != .resolved
                    && $0.kind == seed.kind
                    && $0.subjectEntityID == seed.subjectEntityID
                    && Self.signature($0.content) == Self.signature(seed.content)
            }) {
                repeatedActiveHypothesis = hypotheses[index].status == .active
                if hypotheses[index].status == .dormant {
                    semanticTransition = true
                }
                hypotheses[index] = supported(
                    hypotheses[index],
                    strength: event.confidence,
                    salience: seed.salience,
                    evidenceIDs: [event.id],
                    at: event.observedAt
                )
                changes.append("hypothesis_supported:\(hypotheses[index].id.uuidString.lowercased())")
            } else {
                let hypothesis = MentalHypothesis(
                    id: seed.id ?? UUID(),
                    kind: seed.kind,
                    subjectEntityID: seed.subjectEntityID,
                    content: seed.content,
                    confidence: seed.confidence * event.confidence,
                    salience: seed.salience,
                    createdAt: event.observedAt,
                    lastSupportedAt: event.observedAt,
                    evidenceIDs: [event.id],
                    status: .active
                )
                hypotheses.append(hypothesis)
                changes.append("hypothesis_created:\(hypothesis.id.uuidString.lowercased())")
                semanticTransition = true
            }
        }

        let updatedDrives = drives.applying(event.driveSignal, weight: event.confidence)
        if updatedDrives != drives {
            drives = updatedDrives
            changes.append("drives")
        }

        // A semantically explicit transition is itself a workspace change even
        // when it carries no scalar patch. This gives late L1 results a newer
        // revision to compare against without manufacturing a hypothesis.
        if changes.isEmpty, event.kind.demandsImmediateReflection {
            changes.append("transition:\(event.kind.rawValue)")
            semanticTransition = true
        }

        let evidenceNovelty = repeatedActiveHypothesis ? min(event.novelty, 0.30) : event.novelty
        let novelty = min(max(max(evidenceNovelty, semanticMagnitude(of: changes)), 0), 1)
        let meaningful = semanticTransition || novelty >= 0.55
        if meaningful, changes.isEmpty {
            changes.append("novel_evidence")
        }
        let processed = Array((state.processedEvidenceIDs + [event.id]).uniqued().suffix(256))
        state = MentalWorkspaceSnapshot(
            schemaVersion: state.schemaVersion,
            // This is a semantic revision. Correlated support may refine a
            // posterior without invalidating an in-flight inference that sees
            // the same situation.
            revision: state.revision + (meaningful ? 1 : 0),
            updatedAt: max(state.updatedAt, event.observedAt),
            restoredStale: meaningful ? false : state.restoredStale,
            context: context,
            hypotheses: boundedHypotheses(hypotheses),
            drives: drives,
            thoughtCandidates: state.thoughtCandidates,
            foregroundThoughtID: state.foregroundThoughtID,
            intentions: state.intentions,
            recentNovelty: max(state.recentNovelty * 0.8, novelty),
            lastThoughtAt: state.lastThoughtAt,
            processedEvidenceIDs: processed
        )
        return transition(
            before: before,
            after: state,
            evidenceID: event.id,
            changes: changes,
            novelty: novelty,
            meaningful: meaningful,
            duplicate: false
        )
    }

    public func applyThoughtUpdate(
        _ update: L1ThoughtUpdate,
        at date: Date = Date(),
        draw: Double? = nil
    ) throws -> WorkspaceTransition {
        guard update.expectedRevision == state.revision else {
            throw PersistentMentalWorkspaceError.staleRevision(
                expected: update.expectedRevision,
                actual: state.revision
            )
        }
        guard !update.innerMonologue.isEmpty else {
            throw PersistentMentalWorkspaceError.invalidThought
        }
        let knownEvidence = Set(state.processedEvidenceIDs)
        for evidenceID in update.evidenceIDs where !knownEvidence.contains(evidenceID) {
            throw PersistentMentalWorkspaceError.unsupportedEvidence(evidenceID)
        }

        let before = state
        var hypotheses = state.hypotheses
        var changes: [String] = []
        for mutation in update.hypothesisMutations {
            try apply(mutation, to: &hypotheses, at: date, changes: &changes)
        }
        let drives = state.drives.applying(update.driveSignal, weight: update.confidence)
        if drives != state.drives { changes.append("drives") }

        var candidates = state.thoughtCandidates
        let normalized = Self.signature(update.innerMonologue)
        let candidateID: UUID
        if let existingIndex = candidates.firstIndex(where: {
            Self.signature($0.content) == normalized && $0.channel == update.channel
        }) {
            let existing = candidates[existingIndex]
            candidateID = existing.id
            candidates[existingIndex] = ThoughtCandidate(
                id: existing.id,
                channel: update.channel,
                content: update.innerMonologue,
                confidence: max(existing.confidence, update.confidence),
                salience: max(existing.salience, update.salience),
                novelty: update.novelty,
                parentThoughtID: update.parentThoughtID ?? existing.parentThoughtID,
                continuity: update.continuity,
                hypothesisIDs: mutationHypothesisIDs(update.hypothesisMutations),
                createdAt: existing.createdAt,
                lastForegroundAt: existing.lastForegroundAt
            )
            changes.append("thought_revised:\(existing.id.uuidString.lowercased())")
        } else {
            let candidate = ThoughtCandidate(
                channel: update.channel,
                content: update.innerMonologue,
                confidence: update.confidence,
                salience: update.salience,
                novelty: update.novelty,
                parentThoughtID: update.parentThoughtID,
                continuity: update.continuity,
                hypothesisIDs: mutationHypothesisIDs(update.hypothesisMutations),
                createdAt: date
            )
            candidateID = candidate.id
            candidates.append(candidate)
            changes.append("thought_created:\(candidate.id.uuidString.lowercased())")
        }

        var intentions = state.intentions
        if let intention = update.intention,
           !intentions.contains(where: { $0.id == intention.id }) {
            intentions.append(intention)
            changes.append("intention_created:\(intention.id.uuidString.lowercased())")
        }
        candidates = boundedCandidates(candidates, preserving: candidateID)
        let foregroundID = selectForeground(
            candidates,
            incumbentID: state.foregroundThoughtID,
            drives: drives,
            draw: draw ?? nextUniform()
        )
        if foregroundID != state.foregroundThoughtID {
            changes.append("foreground_changed:\(foregroundID?.uuidString.lowercased() ?? "none")")
        }
        candidates = candidates.map { candidate in
            guard candidate.id == foregroundID else { return candidate }
            return ThoughtCandidate(
                id: candidate.id,
                channel: candidate.channel,
                content: candidate.content,
                confidence: candidate.confidence,
                salience: candidate.salience,
                novelty: candidate.novelty,
                parentThoughtID: candidate.parentThoughtID,
                continuity: candidate.continuity,
                hypothesisIDs: candidate.hypothesisIDs,
                createdAt: candidate.createdAt,
                lastForegroundAt: date
            )
        }
        state = MentalWorkspaceSnapshot(
            schemaVersion: state.schemaVersion,
            revision: state.revision + 1,
            updatedAt: date,
            restoredStale: false,
            context: state.context,
            hypotheses: boundedHypotheses(hypotheses),
            drives: drives,
            thoughtCandidates: candidates,
            foregroundThoughtID: foregroundID,
            intentions: Array(intentions.suffix(16)),
            recentNovelty: max(state.recentNovelty * 0.7, update.novelty),
            lastThoughtAt: date,
            processedEvidenceIDs: state.processedEvidenceIDs
        )
        return transition(
            before: before,
            after: state,
            evidenceID: update.evidenceIDs.last ?? "l1-thought",
            changes: changes,
            novelty: update.novelty,
            meaningful: foregroundID != before.foregroundThoughtID,
            duplicate: false
        )
    }

    public func markIntentionExecuted(_ id: UUID, at date: Date = Date()) -> Bool {
        guard let index = state.intentions.firstIndex(where: { $0.id == id && $0.executedAt == nil }) else {
            return false
        }
        var intentions = state.intentions
        let intention = intentions[index]
        intentions[index] = MentalIntention(
            id: intention.id,
            domain: intention.domain,
            objective: intention.objective,
            attentionTargetLabel: intention.attentionTargetLabel,
            pressure: intention.pressure,
            evidenceIDs: intention.evidenceIDs,
            createdAt: intention.createdAt,
            executedAt: date
        )
        state = MentalWorkspaceSnapshot(
            schemaVersion: state.schemaVersion,
            revision: state.revision + 1,
            updatedAt: date,
            restoredStale: state.restoredStale,
            context: state.context,
            hypotheses: state.hypotheses,
            drives: state.drives,
            thoughtCandidates: state.thoughtCandidates,
            foregroundThoughtID: state.foregroundThoughtID,
            intentions: intentions,
            recentNovelty: state.recentNovelty,
            lastThoughtAt: state.lastThoughtAt,
            processedEvidenceIDs: state.processedEvidenceIDs
        )
        return true
    }

    public func periodicThoughtProbability(
        at date: Date = Date(),
        samplingWindowSeconds: Double = 1
    ) -> Double {
        let elapsed = max(0, date.timeIntervalSince(state.lastThoughtAt ?? state.updatedAt))
        let unresolved = state.hypotheses
            .filter { $0.status == .active || $0.status == .dormant }
            .map { $0.confidence * $0.salience }
            .max() ?? 0
        let drive = max(
            state.drives.curiosity,
            state.drives.concern,
            state.drives.boredom,
            state.drives.socialInterest
        )
        let pressure = 0.50 * unresolved + 0.35 * drive + 0.15 * state.recentNovelty
        let timeBoost = 0.65 + 0.70 * (1 - exp(-elapsed / policy.quietExpectedThoughtIntervalSeconds))
        let hazardPerSecond = timeBoost * (0.55 + pressure)
            / policy.quietExpectedThoughtIntervalSeconds
        let window = min(max(samplingWindowSeconds, 0.05), 60)
        return min(max(1 - exp(-hazardPerSecond * window), 0), 0.98)
    }

    public func shouldInitiatePeriodicThought(
        at date: Date = Date(),
        samplingWindowSeconds: Double = 1,
        draw: Double? = nil
    ) -> Bool {
        let sample = min(max(draw ?? nextUniform(), 0), 1)
        return sample < periodicThoughtProbability(
            at: date,
            samplingWindowSeconds: samplingWindowSeconds
        )
    }

    private func advanceDynamics(to date: Date) {
        guard date > state.updatedAt else { return }
        var hypotheses = state.hypotheses
        var changed = false
        for index in hypotheses.indices {
            let hypothesis = hypotheses[index]
            guard hypothesis.status == .active || hypothesis.status == .dormant else { continue }
            let elapsed = max(0, date.timeIntervalSince(hypothesis.lastSupportedAt))
            let retention = pow(0.5, elapsed / policy.halfLife(for: hypothesis.kind))
            let confidence = hypothesis.confidence * retention
            let salience = hypothesis.salience * sqrt(retention)
            let status: MentalHypothesisStatus
            if confidence <= policy.abandonedConfidence {
                status = .abandoned
            } else if confidence <= policy.dormantConfidence {
                status = .dormant
            } else {
                status = .active
            }
            guard abs(confidence - hypothesis.confidence) >= 0.005 || status != hypothesis.status else {
                continue
            }
            hypotheses[index] = MentalHypothesis(
                id: hypothesis.id,
                kind: hypothesis.kind,
                subjectEntityID: hypothesis.subjectEntityID,
                content: hypothesis.content,
                confidence: confidence,
                salience: salience,
                createdAt: hypothesis.createdAt,
                lastSupportedAt: hypothesis.lastSupportedAt,
                lastContradictedAt: hypothesis.lastContradictedAt,
                evidenceIDs: hypothesis.evidenceIDs,
                status: status
            )
            changed = true
        }
        guard changed else { return }
        state = MentalWorkspaceSnapshot(
            schemaVersion: state.schemaVersion,
            revision: state.revision + 1,
            updatedAt: date,
            restoredStale: state.restoredStale,
            context: state.context,
            hypotheses: hypotheses,
            drives: state.drives,
            thoughtCandidates: state.thoughtCandidates,
            foregroundThoughtID: state.foregroundThoughtID,
            intentions: state.intentions,
            recentNovelty: state.recentNovelty * 0.8,
            lastThoughtAt: state.lastThoughtAt,
            processedEvidenceIDs: state.processedEvidenceIDs
        )
    }

    private func apply(
        _ patch: MentalContextPatch,
        to context: MentalContextState,
        event: MentalEvidenceEvent
    ) -> MentalContextState {
        let availability = patch.socialAvailability ?? context.socialAvailability
        // Relationship uncertainty is authoritative memory context. When it is
        // supplied, replace rather than blend it so every reasoning path sees
        // one canonical value.
        let relationship = patch.relationshipUncertainty ?? context.relationshipUncertainty
        let present = patch.presentEntityIDs ?? context.presentEntityIDs
        let eyeContact = patch.eyeContactActive ?? context.eyeContactActive
        let speaking = patch.participantSpeaking ?? context.participantSpeaking
        let conversation = patch.conversationActive ?? context.conversationActive
        guard present != context.presentEntityIDs
                || eyeContact != context.eyeContactActive
                || speaking != context.participantSpeaking
                || conversation != context.conversationActive
                || abs(availability - context.socialAvailability) >= 0.001
                || abs(relationship - context.relationshipUncertainty) >= 0.001 else {
            return context
        }
        return MentalContextState(
            presentEntityIDs: present,
            eyeContactActive: eyeContact,
            participantSpeaking: speaking,
            conversationActive: conversation,
            socialAvailability: availability,
            relationshipUncertainty: relationship,
            updatedAt: event.observedAt,
            evidenceIDs: context.evidenceIDs + [event.id]
        )
    }

    private func apply(
        _ mutation: MentalHypothesisMutation,
        to hypotheses: inout [MentalHypothesis],
        at date: Date,
        changes: inout [String]
    ) throws {
        switch mutation.operation {
        case .propose:
            guard let seed = mutation.seed, !seed.content.isEmpty else {
                throw PersistentMentalWorkspaceError.invalidThought
            }
            let hypothesis = MentalHypothesis(
                id: seed.id ?? UUID(),
                kind: seed.kind,
                subjectEntityID: seed.subjectEntityID,
                content: seed.content,
                confidence: seed.confidence * mutation.strength,
                salience: seed.salience,
                createdAt: date,
                lastSupportedAt: date,
                evidenceIDs: mutation.evidenceIDs,
                status: .active
            )
            hypotheses.append(hypothesis)
            changes.append("hypothesis_created:\(hypothesis.id.uuidString.lowercased())")
        case .support, .contradict, .resolve, .abandon:
            guard let id = mutation.hypothesisID,
                  let index = hypotheses.firstIndex(where: { $0.id == id }) else {
                throw PersistentMentalWorkspaceError.unknownHypothesis(mutation.hypothesisID ?? UUID())
            }
            let hypothesis = hypotheses[index]
            switch mutation.operation {
            case .support:
                hypotheses[index] = supported(
                    hypothesis,
                    strength: mutation.strength,
                    salience: hypothesis.salience,
                    evidenceIDs: mutation.evidenceIDs,
                    at: date
                )
                changes.append("hypothesis_supported:\(id.uuidString.lowercased())")
            case .contradict:
                let confidence = Self.logistic(
                    Self.logit(hypothesis.confidence) - policy.contradictionLogOdds * mutation.strength
                )
                let status: MentalHypothesisStatus = confidence <= policy.abandonedConfidence
                    ? .abandoned
                    : (confidence <= policy.dormantConfidence ? .dormant : .active)
                hypotheses[index] = MentalHypothesis(
                    id: hypothesis.id,
                    kind: hypothesis.kind,
                    subjectEntityID: hypothesis.subjectEntityID,
                    content: hypothesis.content,
                    confidence: confidence,
                    salience: hypothesis.salience,
                    createdAt: hypothesis.createdAt,
                    lastSupportedAt: hypothesis.lastSupportedAt,
                    lastContradictedAt: date,
                    evidenceIDs: hypothesis.evidenceIDs + mutation.evidenceIDs,
                    status: status
                )
                changes.append("hypothesis_contradicted:\(id.uuidString.lowercased())")
            case .resolve, .abandon:
                let status: MentalHypothesisStatus = mutation.operation == .resolve ? .resolved : .abandoned
                hypotheses[index] = MentalHypothesis(
                    id: hypothesis.id,
                    kind: hypothesis.kind,
                    subjectEntityID: hypothesis.subjectEntityID,
                    content: hypothesis.content,
                    confidence: hypothesis.confidence,
                    salience: hypothesis.salience,
                    createdAt: hypothesis.createdAt,
                    lastSupportedAt: hypothesis.lastSupportedAt,
                    lastContradictedAt: mutation.operation == .abandon ? date : hypothesis.lastContradictedAt,
                    evidenceIDs: hypothesis.evidenceIDs + mutation.evidenceIDs,
                    status: status
                )
                changes.append("hypothesis_\(status.rawValue):\(id.uuidString.lowercased())")
            case .propose:
                break
            }
        }
    }

    private func supported(
        _ hypothesis: MentalHypothesis,
        strength: Double,
        salience: Double,
        evidenceIDs: [String],
        at date: Date
    ) -> MentalHypothesis {
        let confidence = Self.logistic(
            Self.logit(hypothesis.confidence) + policy.supportLogOdds * min(max(strength, 0), 1)
        )
        return MentalHypothesis(
            id: hypothesis.id,
            kind: hypothesis.kind,
            subjectEntityID: hypothesis.subjectEntityID,
            content: hypothesis.content,
            confidence: confidence,
            salience: max(hypothesis.salience, salience),
            createdAt: hypothesis.createdAt,
            lastSupportedAt: date,
            lastContradictedAt: hypothesis.lastContradictedAt,
            evidenceIDs: hypothesis.evidenceIDs + evidenceIDs,
            status: .active
        )
    }

    private func selectForeground(
        _ candidates: [ThoughtCandidate],
        incumbentID: UUID?,
        drives: MentalDriveState,
        draw: Double
    ) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        let logits = candidates.map { candidate -> Double in
            let driveRelevance: Double
            switch candidate.channel {
            case .curiosity: driveRelevance = drives.curiosity
            case .social: driveRelevance = drives.socialInterest
            case .selfCorrection: driveRelevance = drives.concern
            case .idle: driveRelevance = drives.boredom * 0.5
            case .perceptual, .memoryAssociation: driveRelevance = max(drives.curiosity, drives.concern)
            }
            let inertia = candidate.id == incumbentID ? policy.foregroundInertia : 0
            return (0.42 * candidate.salience
                + 0.28 * candidate.confidence
                + 0.18 * candidate.novelty
                + 0.12 * driveRelevance
                + inertia) / policy.foregroundTemperature
        }
        let maximum = logits.max() ?? 0
        let weights = logits.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        var threshold = min(max(draw, 0), 1) * total
        for (index, weight) in weights.enumerated() {
            threshold -= weight
            if threshold <= 0 { return candidates[index].id }
        }
        return candidates.last?.id
    }

    private func boundedHypotheses(_ values: [MentalHypothesis]) -> [MentalHypothesis] {
        Array(values.sorted { lhs, rhs in
            let lhsLive = lhs.status == .active || lhs.status == .dormant
            let rhsLive = rhs.status == .active || rhs.status == .dormant
            if lhsLive != rhsLive { return lhsLive }
            return lhs.salience * lhs.confidence > rhs.salience * rhs.confidence
        }.prefix(32))
    }

    private func boundedCandidates(_ values: [ThoughtCandidate], preserving id: UUID) -> [ThoughtCandidate] {
        if values.count <= 16 { return values }
        let retained = values.sorted { lhs, rhs in
            if lhs.id == id { return true }
            if rhs.id == id { return false }
            return lhs.createdAt > rhs.createdAt
        }.prefix(16)
        return Array(retained.sorted { $0.createdAt < $1.createdAt })
    }

    private func mutationHypothesisIDs(_ mutations: [MentalHypothesisMutation]) -> [UUID] {
        mutations.compactMap { $0.hypothesisID ?? $0.seed?.id }.uniqued()
    }

    private func semanticMagnitude(of changes: [String]) -> Double {
        guard !changes.isEmpty else { return 0 }
        let strongest = changes.map { change -> Double in
            if change.hasPrefix("hypothesis_created:") { return 0.70 }
            if change.hasPrefix("hypothesis_contradicted:") { return 0.80 }
            if change.hasPrefix("foreground_changed:") { return 0.75 }
            if change == "context" { return 0.55 }
            return 0.25
        }.max() ?? 0
        return min(strongest + 0.03 * Double(max(changes.count - 1, 0)), 1)
    }

    private func transition(
        before: MentalWorkspaceSnapshot,
        after: MentalWorkspaceSnapshot,
        evidenceID: String,
        changes: [String],
        novelty: Double,
        meaningful: Bool,
        duplicate: Bool
    ) -> WorkspaceTransition {
        WorkspaceTransition(
            before: before,
            after: after,
            delta: MentalStateDelta(
                evidenceID: evidenceID,
                beforeRevision: before.revision,
                afterRevision: after.revision,
                changedFields: changes,
                novelty: novelty,
                meaningfulTransition: meaningful,
                duplicateEvidence: duplicate
            )
        )
    }

    private static func signature(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func logit(_ value: Double) -> Double {
        let bounded = min(max(value, 0.000_001), 0.999_999)
        return log(bounded / (1 - bounded))
    }

    private static func logistic(_ value: Double) -> Double {
        1 / (1 + exp(-value))
    }

    private func nextUniform() -> Double {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(randomState >> 11) / Double(1 << 53)
    }
}

private struct MentalWorkspaceCheckpointEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let algorithm: String
    let ciphertext: String
}

public actor MentalWorkspaceCheckpointStore {
    public static let checkpointFilename = "mental-workspace.encjson"

    private let checkpointURL: URL
    private let key: SymmetricKey

    public init(directoryURL: URL, encryptionKey: CognitiveMemoryEncryptionKey) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        checkpointURL = directoryURL.appendingPathComponent(Self.checkpointFilename)
        key = SymmetricKey(data: encryptionKey.rawRepresentation)
    }

    public func save(_ snapshot: MentalWorkspaceSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw PersistentMentalWorkspaceError.corruptCheckpoint
        }
        let envelope = MentalWorkspaceCheckpointEnvelope(
            schemaVersion: MentalWorkspaceCheckpointEnvelope.currentSchemaVersion,
            algorithm: "AES.GCM.256",
            ciphertext: combined.base64EncodedString()
        )
        let data = try encoder.encode(envelope)
        try data.write(to: checkpointURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
    }

    public func loadSelective(at date: Date = Date()) throws -> MentalWorkspaceSnapshot? {
        try Self.loadSelective(checkpointURL: checkpointURL, key: key, at: date)
    }

    public static func loadSelective(
        directoryURL: URL,
        encryptionKey: CognitiveMemoryEncryptionKey,
        at date: Date = Date()
    ) throws -> MentalWorkspaceSnapshot? {
        try loadSelective(
            checkpointURL: directoryURL.appendingPathComponent(checkpointFilename),
            key: SymmetricKey(data: encryptionKey.rawRepresentation),
            at: date
        )
    }

    private static func loadSelective(
        checkpointURL: URL,
        key: SymmetricKey,
        at date: Date
    ) throws -> MentalWorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: checkpointURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(MentalWorkspaceCheckpointEnvelope.self, from: data)
            guard envelope.schemaVersion == MentalWorkspaceCheckpointEnvelope.currentSchemaVersion,
                  envelope.algorithm == "AES.GCM.256",
                  let combined = Data(base64Encoded: envelope.ciphertext) else {
                throw PersistentMentalWorkspaceError.corruptCheckpoint
            }
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            let saved = try decoder.decode(MentalWorkspaceSnapshot.self, from: plaintext)
            guard saved.schemaVersion == MentalWorkspaceSnapshot.currentSchemaVersion else {
                throw PersistentMentalWorkspaceError.corruptCheckpoint
            }
            let durableHypotheses = saved.hypotheses.filter {
                $0.status == .active || $0.status == .dormant
            }
            let pendingIntentions = saved.intentions.filter { $0.executedAt == nil }.map {
                MentalIntention(
                    id: $0.id,
                    domain: $0.domain,
                    objective: $0.objective,
                    attentionTargetLabel: $0.attentionTargetLabel,
                    pressure: 0,
                    evidenceIDs: $0.evidenceIDs,
                    createdAt: $0.createdAt
                )
            }
            return MentalWorkspaceSnapshot(
                revision: saved.revision,
                updatedAt: date,
                restoredStale: true,
                context: .staleRestored(
                    at: date,
                    relationshipUncertainty: saved.context.relationshipUncertainty
                ),
                hypotheses: durableHypotheses,
                drives: MentalDriveState(
                    curiosity: saved.drives.curiosity,
                    concern: saved.drives.concern,
                    boredom: saved.drives.boredom,
                    socialInterest: saved.drives.socialInterest,
                    interruptionPressure: 0
                ),
                thoughtCandidates: saved.thoughtCandidates,
                foregroundThoughtID: saved.foregroundThoughtID,
                intentions: pendingIntentions,
                recentNovelty: 0,
                lastThoughtAt: saved.lastThoughtAt,
                processedEvidenceIDs: []
            )
        } catch let error as PersistentMentalWorkspaceError {
            throw error
        } catch {
            throw PersistentMentalWorkspaceError.corruptCheckpoint
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
