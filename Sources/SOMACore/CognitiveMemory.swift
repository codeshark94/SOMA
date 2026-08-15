import CryptoKit
import Darwin
import Foundation

public enum MemoryTier: String, Codable, CaseIterable, Hashable, Sendable {
    case shortTerm = "short_term"
    case mediumTerm = "medium_term"
    case longTerm = "long_term"

    fileprivate var rank: Int {
        switch self {
        case .shortTerm: 0
        case .mediumTerm: 1
        case .longTerm: 2
        }
    }
}

public enum MemoryKind: String, Codable, CaseIterable, Hashable, Sendable {
    case entity
    case identity
    case relationship
    case personFact = "person_fact"
    case space
    case episode
    case task
    case situation
    case openQuestion = "open_question"
    case memoryLink = "memory_link"
}

public enum MemorySensitivity: String, Codable, CaseIterable, Hashable, Sendable {
    case ordinary
    case personal
    case biometric
    case secret
}

public enum MemoryDisclosure: String, Codable, CaseIterable, Hashable, Sendable {
    case localOnly = "local_only"
    case remoteSummaryAllowed = "remote_summary_allowed"
}

public enum MemorySourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case explicitUser = "explicit_user"
    case sensorSummary = "sensor_summary"
    case l1Inference = "l1_inference"
    case l2Interaction = "l2_interaction"
    case identityEnrollment = "identity_enrollment"
    case taskSystem = "task_system"
    case consolidation
}

public struct MemoryProvenance: Codable, Equatable, Sendable {
    public let source: MemorySourceKind
    public let sourceID: String
    public let observedAt: Date
    public let evidenceIDs: [String]
    public let modelID: String?

    public init(
        source: MemorySourceKind,
        sourceID: String,
        observedAt: Date,
        evidenceIDs: [String] = [],
        modelID: String? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.observedAt = observedAt
        self.evidenceIDs = evidenceIDs
        self.modelID = modelID
    }
}

public enum MemoryEntityType: String, Codable, CaseIterable, Hashable, Sendable {
    case person
    case object
    case place
    case organization
    case unknown
}

public struct EntityMemory: Codable, Equatable, Sendable {
    public let type: MemoryEntityType
    public let aliases: [String]

    public init(type: MemoryEntityType, aliases: [String] = []) {
        self.type = type
        self.aliases = aliases
    }
}

public enum IdentityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case candidate
    case confirmed
}

public enum IdentityConsentScope: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case session
    case persistent
}

public struct IdentityMemory: Codable, Equatable, Sendable {
    public let entityID: UUID
    public let status: IdentityStatus
    public let displayName: String?
    public let localRecognitionReference: String?
    public let consentScope: IdentityConsentScope

    public init(
        entityID: UUID,
        status: IdentityStatus,
        displayName: String? = nil,
        localRecognitionReference: String? = nil,
        consentScope: IdentityConsentScope = .none
    ) {
        self.entityID = entityID
        self.status = status
        self.displayName = displayName
        self.localRecognitionReference = localRecognitionReference
        self.consentScope = consentScope
    }
}

public enum ProactiveContactPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case allowed
    case askFirst = "ask_first"
    case avoid
}

public struct RapportProfile: Codable, Equatable, Sendable {
    public let familiarity: Double
    public let interactionComfort: Double
    public let communicationAlignment: Double
    public let proactiveContact: ProactiveContactPreference

    public init(
        familiarity: Double,
        interactionComfort: Double,
        communicationAlignment: Double,
        proactiveContact: ProactiveContactPreference = .unknown
    ) {
        self.familiarity = familiarity
        self.interactionComfort = interactionComfort
        self.communicationAlignment = communicationAlignment
        self.proactiveContact = proactiveContact
    }
}

public struct RelationshipMemory: Codable, Equatable, Sendable {
    public let personEntityID: UUID
    public let rapport: RapportProfile

    public init(personEntityID: UUID, rapport: RapportProfile) {
        self.personEntityID = personEntityID
        self.rapport = rapport
    }
}

public struct PersonFactMemory: Codable, Equatable, Sendable {
    public let personEntityID: UUID
    public let key: String
    public let value: String

    public init(personEntityID: UUID, key: String, value: String) {
        self.personEntityID = personEntityID
        self.key = key
        self.value = value
    }
}

public struct SpaceMemory: Codable, Equatable, Sendable {
    public let name: String
    public let atlasID: UUID?
    public let landmarkIDs: [String]
    public let familiarity: Double

    public init(
        name: String,
        atlasID: UUID? = nil,
        landmarkIDs: [String] = [],
        familiarity: Double
    ) {
        self.name = name
        self.atlasID = atlasID
        self.landmarkIDs = landmarkIDs
        self.familiarity = familiarity
    }
}

public struct EpisodeMemory: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let participantEntityIDs: [UUID]
    public let spaceID: UUID?
    public let taskIDs: [UUID]

    public init(
        startedAt: Date,
        endedAt: Date,
        participantEntityIDs: [UUID] = [],
        spaceID: UUID? = nil,
        taskIDs: [UUID] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.participantEntityIDs = participantEntityIDs
        self.spaceID = spaceID
        self.taskIDs = taskIDs
    }
}

public enum MemoryTaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planned
    case active
    case blocked
    case completed
    case cancelled
}

public struct TaskMemory: Codable, Equatable, Sendable {
    public let title: String
    public let status: MemoryTaskStatus
    public let ownerEntityID: UUID?
    public let blockers: [String]
    public let nextAction: String?
    public let artifactReferences: [String]

    public init(
        title: String,
        status: MemoryTaskStatus,
        ownerEntityID: UUID? = nil,
        blockers: [String] = [],
        nextAction: String? = nil,
        artifactReferences: [String] = []
    ) {
        self.title = title
        self.status = status
        self.ownerEntityID = ownerEntityID
        self.blockers = blockers
        self.nextAction = nextAction
        self.artifactReferences = artifactReferences
    }
}

public struct SituationMemory: Codable, Equatable, Sendable {
    public let state: String
    public let participantEntityIDs: [UUID]
    public let spaceID: UUID?
    public let activeTaskIDs: [UUID]

    public init(
        state: String,
        participantEntityIDs: [UUID] = [],
        spaceID: UUID? = nil,
        activeTaskIDs: [UUID] = []
    ) {
        self.state = state
        self.participantEntityIDs = participantEntityIDs
        self.spaceID = spaceID
        self.activeTaskIDs = activeTaskIDs
    }
}

public enum OpenQuestionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case open
    case deferred
    case resolved
    case dismissed
}

public struct OpenQuestionMemory: Codable, Equatable, Sendable {
    public let question: String
    public let targetEntityID: UUID?
    public let expectedInformationGain: Double
    public let cooldownUntil: Date?
    public let status: OpenQuestionStatus

    public init(
        question: String,
        targetEntityID: UUID? = nil,
        expectedInformationGain: Double,
        cooldownUntil: Date? = nil,
        status: OpenQuestionStatus = .open
    ) {
        self.question = question
        self.targetEntityID = targetEntityID
        self.expectedInformationGain = expectedInformationGain
        self.cooldownUntil = cooldownUntil
        self.status = status
    }
}

public enum MemoryLinkType: String, Codable, CaseIterable, Hashable, Sendable {
    case related
    case locatedIn = "located_in"
    case participatedIn = "participated_in"
    case supports
    case contradicts
    case derivedFrom = "derived_from"
}

public struct MemoryLink: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let targetID: UUID
    public let type: MemoryLinkType

    public init(sourceID: UUID, targetID: UUID, type: MemoryLinkType) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.type = type
    }
}

public enum CognitiveMemoryPayload: Equatable, Sendable {
    case entity(EntityMemory)
    case identity(IdentityMemory)
    case relationship(RelationshipMemory)
    case personFact(PersonFactMemory)
    case space(SpaceMemory)
    case episode(EpisodeMemory)
    case task(TaskMemory)
    case situation(SituationMemory)
    case openQuestion(OpenQuestionMemory)
    case memoryLink(MemoryLink)

    public var kind: MemoryKind {
        switch self {
        case .entity: .entity
        case .identity: .identity
        case .relationship: .relationship
        case .personFact: .personFact
        case .space: .space
        case .episode: .episode
        case .task: .task
        case .situation: .situation
        case .openQuestion: .openQuestion
        case .memoryLink: .memoryLink
        }
    }

    public var relatedIDs: Set<UUID> {
        switch self {
        case .entity:
            []
        case let .identity(value):
            [value.entityID]
        case let .relationship(value):
            [value.personEntityID]
        case let .personFact(value):
            [value.personEntityID]
        case let .space(value):
            value.atlasID.map { [$0] } ?? []
        case let .episode(value):
            Set(value.participantEntityIDs + value.taskIDs + [value.spaceID].compactMap { $0 })
        case let .task(value):
            Set([value.ownerEntityID].compactMap { $0 })
        case let .situation(value):
            Set(value.participantEntityIDs + value.activeTaskIDs + [value.spaceID].compactMap { $0 })
        case let .openQuestion(value):
            Set([value.targetEntityID].compactMap { $0 })
        case let .memoryLink(value):
            [value.sourceID, value.targetID]
        }
    }
}

extension CognitiveMemoryPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(MemoryKind.self, forKey: .type)
        switch kind {
        case .entity: self = .entity(try container.decode(EntityMemory.self, forKey: .value))
        case .identity: self = .identity(try container.decode(IdentityMemory.self, forKey: .value))
        case .relationship: self = .relationship(try container.decode(RelationshipMemory.self, forKey: .value))
        case .personFact: self = .personFact(try container.decode(PersonFactMemory.self, forKey: .value))
        case .space: self = .space(try container.decode(SpaceMemory.self, forKey: .value))
        case .episode: self = .episode(try container.decode(EpisodeMemory.self, forKey: .value))
        case .task: self = .task(try container.decode(TaskMemory.self, forKey: .value))
        case .situation: self = .situation(try container.decode(SituationMemory.self, forKey: .value))
        case .openQuestion: self = .openQuestion(try container.decode(OpenQuestionMemory.self, forKey: .value))
        case .memoryLink: self = .memoryLink(try container.decode(MemoryLink.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case let .entity(value): try container.encode(value, forKey: .value)
        case let .identity(value): try container.encode(value, forKey: .value)
        case let .relationship(value): try container.encode(value, forKey: .value)
        case let .personFact(value): try container.encode(value, forKey: .value)
        case let .space(value): try container.encode(value, forKey: .value)
        case let .episode(value): try container.encode(value, forKey: .value)
        case let .task(value): try container.encode(value, forKey: .value)
        case let .situation(value): try container.encode(value, forKey: .value)
        case let .openQuestion(value): try container.encode(value, forKey: .value)
        case let .memoryLink(value): try container.encode(value, forKey: .value)
        }
    }
}

public struct CognitiveMemoryDraft: Equatable, Sendable {
    public let tier: MemoryTier
    public let summary: String
    public let payload: CognitiveMemoryPayload
    public let confidence: Double
    public let provenance: [MemoryProvenance]
    public let sensitivity: MemorySensitivity
    public let disclosure: MemoryDisclosure
    public let expiresAt: Date?

    public init(
        tier: MemoryTier,
        summary: String,
        payload: CognitiveMemoryPayload,
        confidence: Double,
        provenance: [MemoryProvenance],
        sensitivity: MemorySensitivity = .ordinary,
        disclosure: MemoryDisclosure = .localOnly,
        expiresAt: Date? = nil
    ) {
        self.tier = tier
        self.summary = summary
        self.payload = payload
        self.confidence = confidence
        self.provenance = provenance
        self.sensitivity = sensitivity
        self.disclosure = disclosure
        self.expiresAt = expiresAt
    }
}

public struct CognitiveMemoryRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let revision: UInt64
    public let tier: MemoryTier
    public let summary: String
    public let payload: CognitiveMemoryPayload
    public let confidence: Double
    public let provenance: [MemoryProvenance]
    public let sensitivity: MemorySensitivity
    public let disclosure: MemoryDisclosure
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date?
    public let supersedesRevision: UInt64?

    fileprivate init(id: UUID, revision: UInt64, draft: CognitiveMemoryDraft, createdAt: Date, updatedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.revision = revision
        tier = draft.tier
        summary = draft.summary
        payload = draft.payload
        confidence = draft.confidence
        provenance = draft.provenance
        sensitivity = draft.sensitivity
        disclosure = draft.disclosure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        expiresAt = draft.expiresAt
        supersedesRevision = revision > 1 ? revision - 1 : nil
    }

    public var kind: MemoryKind { payload.kind }
    public var relatedIDs: Set<UUID> { payload.relatedIDs.union([id]) }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }

    fileprivate var draft: CognitiveMemoryDraft {
        CognitiveMemoryDraft(
            tier: tier,
            summary: summary,
            payload: payload,
            confidence: confidence,
            provenance: provenance,
            sensitivity: sensitivity,
            disclosure: disclosure,
            expiresAt: expiresAt
        )
    }
}

public struct CognitiveMemoryValidationPolicy: Equatable, Sendable {
    public let maximumSummaryBytes: Int
    public let maximumFieldBytes: Int
    public let maximumArrayItems: Int
    public let maximumShortTermLifetime: TimeInterval
    public let maximumMediumTermLifetime: TimeInterval

    public init(
        maximumSummaryBytes: Int = 4_096,
        maximumFieldBytes: Int = 2_048,
        maximumArrayItems: Int = 128,
        maximumShortTermLifetime: TimeInterval = 24 * 60 * 60,
        maximumMediumTermLifetime: TimeInterval = 180 * 24 * 60 * 60
    ) {
        self.maximumSummaryBytes = maximumSummaryBytes
        self.maximumFieldBytes = maximumFieldBytes
        self.maximumArrayItems = maximumArrayItems
        self.maximumShortTermLifetime = maximumShortTermLifetime
        self.maximumMediumTermLifetime = maximumMediumTermLifetime
    }
}

public enum CognitiveMemoryError: Error, Equatable, Sendable {
    case invalidEncryptionKeyLength
    case storeLocked
    case storeClosed
    case unsupportedSchema(Int)
    case corruptJournal(line: Int)
    case validationFailed([String])
    case recordNotFound(UUID)
    case recordAlreadyExists(UUID)
    case revisionConflict(UUID)
    case nonMonotonicUpdate(UUID)
    case kindChangeNotAllowed
    case tierChangeRequiresPromotion
    case tierDowngradeNotAllowed
    case invalidReason
}

public struct CognitiveMemoryValidator: Sendable {
    public let policy: CognitiveMemoryValidationPolicy

    public init(policy: CognitiveMemoryValidationPolicy = .init()) {
        self.policy = policy
    }

    public func validate(_ record: CognitiveMemoryRecord) throws {
        var failures: [String] = []
        if record.schemaVersion != CognitiveMemoryRecord.currentSchemaVersion {
            failures.append("unsupported record schema")
        }
        if record.revision == 0 { failures.append("revision must be positive") }
        if record.revision == 1, record.supersedesRevision != nil {
            failures.append("first revision cannot supersede another revision")
        }
        if record.revision > 1, record.supersedesRevision != record.revision - 1 {
            failures.append("revision must identify the revision it supersedes")
        }
        validateRequired(record.summary, name: "summary", maximum: policy.maximumSummaryBytes, failures: &failures)
        if !(0 ... 1).contains(record.confidence) { failures.append("confidence must be in 0...1") }
        if record.createdAt > record.updatedAt { failures.append("createdAt must not follow updatedAt") }
        if record.provenance.isEmpty { failures.append("provenance is required") }
        if record.provenance.count > policy.maximumArrayItems { failures.append("too many provenance entries") }
        for provenance in record.provenance {
            validateRequired(provenance.sourceID, name: "provenance sourceID", failures: &failures)
            validateOptional(provenance.modelID, name: "provenance modelID", failures: &failures)
            validateStrings(provenance.evidenceIDs, name: "evidence IDs", failures: &failures)
            if provenance.source == .l1Inference && provenance.evidenceIDs.isEmpty {
                failures.append("L1 inference requires evidence IDs")
            }
        }
        validateLifecycle(record, failures: &failures)
        validateDisclosure(record, failures: &failures)
        validatePayload(record, failures: &failures)
        if !failures.isEmpty { throw CognitiveMemoryError.validationFailed(failures) }
    }

    private func validateLifecycle(_ record: CognitiveMemoryRecord, failures: inout [String]) {
        switch record.tier {
        case .shortTerm:
            validateExpiry(record, maximumLifetime: policy.maximumShortTermLifetime, failures: &failures)
        case .mediumTerm:
            validateExpiry(record, maximumLifetime: policy.maximumMediumTermLifetime, failures: &failures)
        case .longTerm:
            if record.expiresAt != nil { failures.append("long-term memory expires only through correction or deletion") }
            let durableSources: Set<MemorySourceKind> = [.explicitUser, .identityEnrollment, .taskSystem, .consolidation]
            if !record.provenance.contains(where: { durableSources.contains($0.source) }) {
                failures.append("long-term memory requires explicit, enrolled, task, or consolidated provenance")
            }
        }
    }

    private func validateExpiry(
        _ record: CognitiveMemoryRecord,
        maximumLifetime: TimeInterval,
        failures: inout [String]
    ) {
        guard let expiresAt = record.expiresAt else {
            failures.append("short- and medium-term memory require an expiry")
            return
        }
        if expiresAt <= record.updatedAt { failures.append("expiry must follow the update time") }
        if expiresAt.timeIntervalSince(record.updatedAt) > maximumLifetime {
            failures.append("expiry exceeds the tier retention policy")
        }
    }

    private func validateDisclosure(_ record: CognitiveMemoryRecord, failures: inout [String]) {
        if record.disclosure == .remoteSummaryAllowed,
           record.sensitivity == .biometric || record.sensitivity == .secret {
            failures.append("biometric and secret memory cannot be projected remotely")
        }
    }

    private func validatePayload(_ record: CognitiveMemoryRecord, failures: inout [String]) {
        switch record.payload {
        case let .entity(value):
            validateStrings(value.aliases, name: "entity aliases", failures: &failures)
        case let .identity(value):
            validateOptional(value.displayName, name: "identity display name", failures: &failures)
            validateOptional(value.localRecognitionReference, name: "recognition reference", failures: &failures)
            if value.status == .confirmed && value.consentScope == .none {
                failures.append("confirmed identity requires consent")
            }
            if value.consentScope == .persistent && value.status != .confirmed {
                failures.append("persistent identity consent requires confirmed identity")
            }
            if value.localRecognitionReference != nil {
                if record.sensitivity != .biometric { failures.append("recognition reference requires biometric sensitivity") }
                if record.disclosure != .localOnly { failures.append("recognition reference must remain local") }
            }
        case let .relationship(value):
            validateUnit(value.rapport.familiarity, name: "rapport familiarity", failures: &failures)
            validateUnit(value.rapport.interactionComfort, name: "rapport interaction comfort", failures: &failures)
            validateUnit(value.rapport.communicationAlignment, name: "rapport communication alignment", failures: &failures)
        case let .personFact(value):
            validateRequired(value.key, name: "person fact key", failures: &failures)
            validateRequired(value.value, name: "person fact value", failures: &failures)
        case let .space(value):
            validateRequired(value.name, name: "space name", failures: &failures)
            validateStrings(value.landmarkIDs, name: "space landmark IDs", failures: &failures)
            validateUnit(value.familiarity, name: "space familiarity", failures: &failures)
        case let .episode(value):
            if value.startedAt > value.endedAt { failures.append("episode start must not follow its end") }
            validateCount(value.participantEntityIDs.count, name: "episode participants", failures: &failures)
            validateCount(value.taskIDs.count, name: "episode tasks", failures: &failures)
        case let .task(value):
            validateRequired(value.title, name: "task title", failures: &failures)
            validateStrings(value.blockers, name: "task blockers", failures: &failures)
            validateOptional(value.nextAction, name: "task next action", failures: &failures)
            validateStrings(value.artifactReferences, name: "task artifact references", failures: &failures)
        case let .situation(value):
            validateRequired(value.state, name: "situation state", failures: &failures)
            validateCount(value.participantEntityIDs.count, name: "situation participants", failures: &failures)
            validateCount(value.activeTaskIDs.count, name: "situation tasks", failures: &failures)
        case let .openQuestion(value):
            validateRequired(value.question, name: "open question", failures: &failures)
            validateUnit(value.expectedInformationGain, name: "expected information gain", failures: &failures)
        case let .memoryLink(value):
            if value.sourceID == value.targetID { failures.append("memory link endpoints must differ") }
        }
    }

    private func validateUnit(_ value: Double, name: String, failures: inout [String]) {
        if !(0 ... 1).contains(value) { failures.append("\(name) must be in 0...1") }
    }

    private func validateRequired(
        _ value: String,
        name: String,
        maximum: Int? = nil,
        failures: inout [String]
    ) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("\(name) is required") }
        if value.utf8.count > (maximum ?? policy.maximumFieldBytes) { failures.append("\(name) is too large") }
    }

    private func validateOptional(_ value: String?, name: String, failures: inout [String]) {
        guard let value else { return }
        validateRequired(value, name: name, failures: &failures)
    }

    private func validateStrings(_ values: [String], name: String, failures: inout [String]) {
        validateCount(values.count, name: name, failures: &failures)
        for value in values { validateRequired(value, name: name, failures: &failures) }
    }

    private func validateCount(_ count: Int, name: String, failures: inout [String]) {
        if count > policy.maximumArrayItems { failures.append("too many \(name)") }
    }
}

public struct CognitiveMemoryQuery: Sendable {
    public let tiers: Set<MemoryTier>?
    public let kinds: Set<MemoryKind>?
    public let relatedTo: Set<UUID>
    public let text: String?
    public let limit: Int

    public init(
        tiers: Set<MemoryTier>? = nil,
        kinds: Set<MemoryKind>? = nil,
        relatedTo: Set<UUID> = [],
        text: String? = nil,
        limit: Int = 50
    ) {
        self.tiers = tiers
        self.kinds = kinds
        self.relatedTo = relatedTo
        self.text = text
        self.limit = min(max(limit, 1), 500)
    }
}

public struct RemoteMemoryProjection: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: UInt64
    public let tier: MemoryTier
    public let kind: MemoryKind
    public let summary: String
    public let confidence: Double
    public let updatedAt: Date
}

public struct CognitiveMemoryStats: Equatable, Sendable {
    public let activeRecords: Int
    public let shortTermRecords: Int
    public let mediumTermRecords: Int
    public let longTermRecords: Int
    public let journalSequence: UInt64
}

public struct CognitiveMemoryEncryptionKey: Sendable {
    fileprivate let data: Data

    private init(validatedData: Data) {
        data = validatedData
    }

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else { throw CognitiveMemoryError.invalidEncryptionKeyLength }
        data = rawRepresentation
    }

    public static func generate() -> CognitiveMemoryEncryptionKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return CognitiveMemoryEncryptionKey(validatedData: data)
    }

    public var rawRepresentation: Data { data }
}

private enum MemoryJournalOperation: String, Codable {
    case upsert
    case delete
}

private struct MemoryJournalEntry: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sequence: UInt64
    let operation: MemoryJournalOperation
    let timestamp: Date
    let record: CognitiveMemoryRecord?
    let recordID: UUID
    let reason: String?
}

private struct MemoryJournalEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let algorithm: String
    let ciphertext: String
}

private struct MemoryJournalCipher {
    private let key: SymmetricKey

    init(key: CognitiveMemoryEncryptionKey) {
        self.key = SymmetricKey(data: key.data)
    }

    func seal(_ entry: MemoryJournalEntry) throws -> Data {
        let encoder = JSONEncoder.cognitiveMemoryEncoder()
        let plaintext = try encoder.encode(entry)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CognitiveMemoryError.corruptJournal(line: 0) }
        let envelope = MemoryJournalEnvelope(
            schemaVersion: MemoryJournalEnvelope.currentSchemaVersion,
            algorithm: "AES.GCM.256",
            ciphertext: combined.base64EncodedString()
        )
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        return data
    }

    func open(_ data: Data, line: Int) throws -> MemoryJournalEntry {
        do {
            let decoder = JSONDecoder.cognitiveMemoryDecoder()
            let envelope = try decoder.decode(MemoryJournalEnvelope.self, from: data)
            guard envelope.schemaVersion == MemoryJournalEnvelope.currentSchemaVersion,
                  envelope.algorithm == "AES.GCM.256",
                  let combined = Data(base64Encoded: envelope.ciphertext) else {
                throw CognitiveMemoryError.corruptJournal(line: line)
            }
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return try decoder.decode(MemoryJournalEntry.self, from: plaintext)
        } catch let error as CognitiveMemoryError {
            throw error
        } catch {
            throw CognitiveMemoryError.corruptJournal(line: line)
        }
    }
}

private extension JSONEncoder {
    static func cognitiveMemoryEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static func cognitiveMemoryDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public actor CognitiveMemoryStore {
    public static let journalFilename = "cognitive-memory.encjsonl"
    public static let lockFilename = "cognitive-memory.lock"

    private let directoryURL: URL
    private let journalURL: URL
    private let cipher: MemoryJournalCipher
    private let validator: CognitiveMemoryValidator
    private let lockHandle: FileHandle
    private var journalHandle: FileHandle
    private var sequence: UInt64
    private var current: [UUID: CognitiveMemoryRecord]
    private var historyByID: [UUID: [CognitiveMemoryRecord]]
    private var closed = false

    private struct OpenedStore {
        let lockHandle: FileHandle
        let journalHandle: FileHandle
        let sequence: UInt64
        let current: [UUID: CognitiveMemoryRecord]
        let historyByID: [UUID: [CognitiveMemoryRecord]]
    }

    public init(
        directoryURL: URL,
        encryptionKey: CognitiveMemoryEncryptionKey,
        policy: CognitiveMemoryValidationPolicy = .init()
    ) throws {
        self.directoryURL = directoryURL
        journalURL = directoryURL.appendingPathComponent(Self.journalFilename)
        cipher = MemoryJournalCipher(key: encryptionKey)
        validator = CognitiveMemoryValidator(policy: policy)
        let opened = try Self.open(
            directoryURL: directoryURL,
            journalURL: journalURL,
            cipher: cipher,
            validator: validator
        )
        lockHandle = opened.lockHandle
        journalHandle = opened.journalHandle
        sequence = opened.sequence
        current = opened.current
        historyByID = opened.historyByID
    }

    deinit {
        if !closed {
            try? journalHandle.close()
            _ = flock(lockHandle.fileDescriptor, LOCK_UN)
            try? lockHandle.close()
        }
    }

    @discardableResult
    public func insert(
        _ draft: CognitiveMemoryDraft,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> CognitiveMemoryRecord {
        try ensureOpen()
        guard current[id] == nil, historyByID[id] == nil else { throw CognitiveMemoryError.recordAlreadyExists(id) }
        let record = CognitiveMemoryRecord(id: id, revision: 1, draft: draft, createdAt: date, updatedAt: date)
        try validator.validate(record)
        try appendUpsert(record, reason: "insert", at: date)
        current[id] = record
        historyByID[id] = [record]
        return record
    }

    @discardableResult
    public func correct(
        id: UUID,
        replacement: CognitiveMemoryDraft,
        reason: String,
        at date: Date = Date()
    ) throws -> CognitiveMemoryRecord {
        try ensureOpen()
        try validateReason(reason)
        guard let previous = current[id] else { throw CognitiveMemoryError.recordNotFound(id) }
        guard replacement.payload.kind == previous.payload.kind else { throw CognitiveMemoryError.kindChangeNotAllowed }
        guard replacement.tier == previous.tier else { throw CognitiveMemoryError.tierChangeRequiresPromotion }
        guard date >= previous.updatedAt else { throw CognitiveMemoryError.nonMonotonicUpdate(id) }
        let record = CognitiveMemoryRecord(
            id: id,
            revision: previous.revision + 1,
            draft: replacement,
            createdAt: previous.createdAt,
            updatedAt: date
        )
        try validator.validate(record)
        try appendUpsert(record, reason: reason, at: date)
        current[id] = record
        historyByID[id, default: []].append(record)
        return record
    }

    @discardableResult
    public func promote(
        id: UUID,
        to tier: MemoryTier,
        expiresAt: Date?,
        provenance: [MemoryProvenance],
        reason: String,
        at date: Date = Date()
    ) throws -> CognitiveMemoryRecord {
        try ensureOpen()
        try validateReason(reason)
        guard let previous = current[id] else { throw CognitiveMemoryError.recordNotFound(id) }
        guard tier.rank > previous.tier.rank else { throw CognitiveMemoryError.tierDowngradeNotAllowed }
        guard date >= previous.updatedAt else { throw CognitiveMemoryError.nonMonotonicUpdate(id) }
        let draft = CognitiveMemoryDraft(
            tier: tier,
            summary: previous.summary,
            payload: previous.payload,
            confidence: previous.confidence,
            provenance: provenance,
            sensitivity: previous.sensitivity,
            disclosure: previous.disclosure,
            expiresAt: expiresAt
        )
        let record = CognitiveMemoryRecord(
            id: id,
            revision: previous.revision + 1,
            draft: draft,
            createdAt: previous.createdAt,
            updatedAt: date
        )
        try validator.validate(record)
        try appendUpsert(record, reason: reason, at: date)
        current[id] = record
        historyByID[id, default: []].append(record)
        return record
    }

    public func delete(id: UUID, reason: String, at date: Date = Date()) throws {
        try ensureOpen()
        try validateReason(reason)
        guard let previous = current[id] else { throw CognitiveMemoryError.recordNotFound(id) }
        guard date >= previous.updatedAt else { throw CognitiveMemoryError.nonMonotonicUpdate(id) }
        let entry = MemoryJournalEntry(
            schemaVersion: MemoryJournalEntry.currentSchemaVersion,
            sequence: sequence + 1,
            operation: .delete,
            timestamp: date,
            record: nil,
            recordID: id,
            reason: reason
        )
        try append(entry)
        current.removeValue(forKey: id)
        historyByID.removeValue(forKey: id)
        try rewriteJournal()
    }

    @discardableResult
    public func purgeExpired(at date: Date = Date()) throws -> [UUID] {
        try ensureOpen()
        let expired = current.values.filter { $0.isExpired(at: date) }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard !expired.isEmpty else { return [] }
        for id in expired {
            let entry = MemoryJournalEntry(
                schemaVersion: MemoryJournalEntry.currentSchemaVersion,
                sequence: sequence + 1,
                operation: .delete,
                timestamp: date,
                record: nil,
                recordID: id,
                reason: "retention_expired"
            )
            try append(entry)
            current.removeValue(forKey: id)
            historyByID.removeValue(forKey: id)
        }
        try rewriteJournal()
        return expired
    }

    public func record(id: UUID, at date: Date = Date()) throws -> CognitiveMemoryRecord? {
        try ensureOpen()
        guard let record = current[id], record.updatedAt <= date, !record.isExpired(at: date) else { return nil }
        return record
    }

    public func history(id: UUID) throws -> [CognitiveMemoryRecord] {
        try ensureOpen()
        return historyByID[id] ?? []
    }

    public func query(_ query: CognitiveMemoryQuery = .init(), at date: Date = Date()) throws -> [CognitiveMemoryRecord] {
        try ensureOpen()
        let normalizedText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return current.values
            .filter { $0.updatedAt <= date }
            .filter { !$0.isExpired(at: date) }
            .filter { query.tiers?.contains($0.tier) ?? true }
            .filter { query.kinds?.contains($0.kind) ?? true }
            .filter { query.relatedTo.isEmpty || !query.relatedTo.isDisjoint(with: $0.relatedIDs) }
            .filter { record in
                guard let normalizedText, !normalizedText.isEmpty else { return true }
                return record.summary.lowercased().contains(normalizedText)
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(query.limit)
            .map { $0 }
    }

    public func remoteProjection(
        _ query: CognitiveMemoryQuery = .init(),
        at date: Date = Date()
    ) throws -> [RemoteMemoryProjection] {
        try self.query(query, at: date)
            .filter {
                $0.disclosure == .remoteSummaryAllowed &&
                    $0.sensitivity != .biometric &&
                    $0.sensitivity != .secret
            }
            .map {
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
    }

    public func stats(at date: Date = Date()) throws -> CognitiveMemoryStats {
        try ensureOpen()
        let records = current.values.filter { $0.updatedAt <= date && !$0.isExpired(at: date) }
        return CognitiveMemoryStats(
            activeRecords: records.count,
            shortTermRecords: records.count { $0.tier == .shortTerm },
            mediumTermRecords: records.count { $0.tier == .mediumTerm },
            longTermRecords: records.count { $0.tier == .longTerm },
            journalSequence: sequence
        )
    }

    public func compact() throws {
        try ensureOpen()
        try rewriteJournal()
    }

    public func close() throws {
        guard !closed else { return }
        try journalHandle.synchronize()
        try journalHandle.close()
        _ = flock(lockHandle.fileDescriptor, LOCK_UN)
        try lockHandle.close()
        closed = true
    }

    private func appendUpsert(_ record: CognitiveMemoryRecord, reason: String, at date: Date) throws {
        let entry = MemoryJournalEntry(
            schemaVersion: MemoryJournalEntry.currentSchemaVersion,
            sequence: sequence + 1,
            operation: .upsert,
            timestamp: date,
            record: record,
            recordID: record.id,
            reason: reason
        )
        try append(entry)
    }

    private func append(_ entry: MemoryJournalEntry) throws {
        guard entry.sequence == sequence + 1 else { throw CognitiveMemoryError.revisionConflict(entry.recordID) }
        let data = try cipher.seal(entry)
        try journalHandle.seekToEnd()
        try journalHandle.write(contentsOf: data)
        try journalHandle.synchronize()
        sequence = entry.sequence
    }

    private func rewriteJournal() throws {
        let tempURL = directoryURL.appendingPathComponent(".cognitive-memory-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let tempHandle = try FileHandle(forWritingTo: tempURL)
        var nextSequence: UInt64 = 0
        do {
            let records = historyByID.values.flatMap { $0 }.sorted {
                if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
                return $0.revision < $1.revision
            }
            for record in records {
                nextSequence += 1
                let entry = MemoryJournalEntry(
                    schemaVersion: MemoryJournalEntry.currentSchemaVersion,
                    sequence: nextSequence,
                    operation: .upsert,
                    timestamp: record.updatedAt,
                    record: record,
                    recordID: record.id,
                    reason: "compacted"
                )
                try tempHandle.write(contentsOf: cipher.seal(entry))
            }
            try tempHandle.synchronize()
            try tempHandle.close()
            try journalHandle.close()
            let renamed = tempURL.path.withCString { source in
                journalURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renamed == 0 else {
                journalHandle = try FileHandle(forUpdating: journalURL)
                try journalHandle.seekToEnd()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            journalHandle = try FileHandle(forUpdating: journalURL)
            try journalHandle.seekToEnd()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            sequence = nextSequence
        } catch {
            try? tempHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
            if (try? journalHandle.offset()) == nil {
                journalHandle = try FileHandle(forUpdating: journalURL)
                try journalHandle.seekToEnd()
            }
            throw error
        }
    }

    private func validateReason(_ reason: String) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= validator.policy.maximumFieldBytes else {
            throw CognitiveMemoryError.invalidReason
        }
    }

    private func ensureOpen() throws {
        if closed { throw CognitiveMemoryError.storeClosed }
    }

    private static func open(
        directoryURL: URL,
        journalURL: URL,
        cipher: MemoryJournalCipher,
        validator: CognitiveMemoryValidator
    ) throws -> OpenedStore {
        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let lockURL = directoryURL.appendingPathComponent(lockFilename)
        if !manager.fileExists(atPath: lockURL.path) {
            manager.createFile(atPath: lockURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if !manager.fileExists(atPath: journalURL.path) {
            manager.createFile(atPath: journalURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)

        let lockHandle = try FileHandle(forUpdating: lockURL)
        guard flock(lockHandle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? lockHandle.close()
            throw CognitiveMemoryError.storeLocked
        }
        do {
            let journalHandle = try FileHandle(forUpdating: journalURL)
            try journalHandle.seek(toOffset: 0)
            let data = try journalHandle.readToEnd() ?? Data()
            let replayed = try replay(data, cipher: cipher, validator: validator)
            try journalHandle.seekToEnd()
            return OpenedStore(
                lockHandle: lockHandle,
                journalHandle: journalHandle,
                sequence: replayed.sequence,
                current: replayed.current,
                historyByID: replayed.historyByID
            )
        } catch {
            _ = flock(lockHandle.fileDescriptor, LOCK_UN)
            try? lockHandle.close()
            throw error
        }
    }

    private static func replay(
        _ data: Data,
        cipher: MemoryJournalCipher,
        validator: CognitiveMemoryValidator
    ) throws -> (
        sequence: UInt64,
        current: [UUID: CognitiveMemoryRecord],
        historyByID: [UUID: [CognitiveMemoryRecord]]
    ) {
        var sequence: UInt64 = 0
        var current: [UUID: CognitiveMemoryRecord] = [:]
        var historyByID: [UUID: [CognitiveMemoryRecord]] = [:]
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            let entry = try cipher.open(Data(line), line: lineNumber)
            guard entry.schemaVersion == MemoryJournalEntry.currentSchemaVersion else {
                throw CognitiveMemoryError.unsupportedSchema(entry.schemaVersion)
            }
            guard entry.sequence == sequence + 1 else { throw CognitiveMemoryError.corruptJournal(line: lineNumber) }
            switch entry.operation {
            case .upsert:
                guard let record = entry.record, record.id == entry.recordID else {
                    throw CognitiveMemoryError.corruptJournal(line: lineNumber)
                }
                try validator.validate(record)
                if let previous = historyByID[record.id]?.last,
                   record.revision != previous.revision + 1 {
                    throw CognitiveMemoryError.revisionConflict(record.id)
                }
                if let previous = historyByID[record.id]?.last,
                   record.createdAt != previous.createdAt || record.updatedAt < previous.updatedAt {
                    throw CognitiveMemoryError.nonMonotonicUpdate(record.id)
                }
                if historyByID[record.id] == nil, record.revision != 1 {
                    throw CognitiveMemoryError.revisionConflict(record.id)
                }
                historyByID[record.id, default: []].append(record)
                current[record.id] = record
            case .delete:
                guard entry.record == nil,
                      let previous = current[entry.recordID],
                      entry.timestamp >= previous.updatedAt else {
                    throw CognitiveMemoryError.corruptJournal(line: lineNumber)
                }
                current.removeValue(forKey: entry.recordID)
                historyByID.removeValue(forKey: entry.recordID)
            }
            sequence = entry.sequence
        }
        return (sequence, current, historyByID)
    }
}
