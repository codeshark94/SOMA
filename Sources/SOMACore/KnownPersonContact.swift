import Foundation
import CryptoKit

public enum FaceIdentityError: Error, Equatable, Sendable {
    case invalidEmbedding
    case incompatibleEmbedding
    case invalidCalibration
    case invalidProfile
}

/// A transient, local-only face representation. The canonical memory store
/// keeps only an opaque recognition reference; this vector must never enter a
/// remote context projection or a scalar runtime trace.
public struct LocalFaceEmbedding: Codable, Equatable, Sendable {
    public let modelID: String
    public let modelRevision: Int
    public let quality: Double
    public let values: [Float]

    public init(
        modelID: String,
        modelRevision: Int,
        quality: Double,
        values: [Float]
    ) throws {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty,
              normalizedModelID.count <= 128,
              modelRevision > 0,
              quality.isFinite,
              (0 ... 1).contains(quality),
              (32 ... 4_096).contains(values.count),
              values.allSatisfy({ $0.isFinite }) else {
            throw FaceIdentityError.invalidEmbedding
        }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1 * $1) })
        guard norm.isFinite, norm > 1e-8 else { throw FaceIdentityError.invalidEmbedding }
        self.modelID = normalizedModelID
        self.modelRevision = modelRevision
        self.quality = quality
        self.values = values.map { Float(Double($0) / norm) }
    }

    public func cosineSimilarity(to other: LocalFaceEmbedding) throws -> Double {
        guard modelID == other.modelID,
              modelRevision == other.modelRevision,
              values.count == other.values.count else {
            throw FaceIdentityError.incompatibleEmbedding
        }
        return zip(values, other.values).reduce(0.0) { $0 + Double($1.0 * $1.1) }
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, modelRevision, quality, values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedModelID = try container.decode(String.self, forKey: .modelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedRevision = try container.decode(Int.self, forKey: .modelRevision)
        let decodedQuality = try container.decode(Double.self, forKey: .quality)
        let decodedValues = try container.decode([Float].self, forKey: .values)
        let norm = sqrt(decodedValues.reduce(0.0) { $0 + Double($1 * $1) })
        guard !decodedModelID.isEmpty,
              decodedModelID.count <= 128,
              decodedRevision > 0,
              decodedQuality.isFinite,
              (0 ... 1).contains(decodedQuality),
              (32 ... 4_096).contains(decodedValues.count),
              decodedValues.allSatisfy({ $0.isFinite }),
              norm.isFinite,
              abs(norm - 1) <= 0.001 else {
            throw DecodingError.dataCorruptedError(
                forKey: .values,
                in: container,
                debugDescription: "Invalid local face embedding"
            )
        }
        modelID = decodedModelID
        modelRevision = decodedRevision
        quality = decodedQuality
        values = decodedValues
    }
}

/// Maintains a compact set of local face references that covers distinct
/// appearance observations instead of retaining a burst of near-identical
/// frames. The references remain local biometric material.
public enum LocalFaceReferenceSet {
    public static let nearDuplicateSimilarity = 0.995
    public static let materialDiversityImprovement = 0.008
    public static let qualityReplacementMargin = 0.08

    /// Inserts an observation when it expands the retained embedding-space
    /// coverage, or replaces a near-duplicate with a materially clearer view.
    /// Returns whether the stored set changed.
    @discardableResult
    public static func retain(
        _ observation: LocalFaceEmbedding,
        in references: inout [LocalFaceEmbedding],
        maximumCount: Int
    ) -> Bool {
        guard (1 ... 24).contains(maximumCount),
              references.count <= maximumCount,
              references.allSatisfy({ isCompatible(observation, $0) }) else {
            return false
        }
        guard !references.isEmpty else {
            references.append(observation)
            return true
        }

        let similarities = references.enumerated().compactMap { index, reference -> (Int, Double)? in
            guard let similarity = try? observation.cosineSimilarity(to: reference) else { return nil }
            return (index, similarity)
        }
        guard let nearest = similarities.max(by: { $0.1 < $1.1 }) else { return false }

        if nearest.1 >= nearDuplicateSimilarity {
            guard observation.quality >= references[nearest.0].quality + qualityReplacementMargin else {
                return false
            }
            references[nearest.0] = observation
            return true
        }

        if references.count < maximumCount {
            references.append(observation)
            return true
        }

        let currentDiversity = minimumPairwiseDiversity(references)
        var replacement: (index: Int, diversity: Double)?
        for index in references.indices {
            var candidate = references
            candidate[index] = observation
            let diversity = minimumPairwiseDiversity(candidate)
            guard let current = replacement else {
                replacement = (index, diversity)
                continue
            }
            if diversity > current.diversity + 1e-12 ||
                (abs(diversity - current.diversity) <= 1e-12 &&
                    references[index].quality < references[current.index].quality) {
                replacement = (index, diversity)
            }
        }
        guard let replacement else { return false }
        let replacedQuality = references[replacement.index].quality
        guard replacement.diversity >= currentDiversity + materialDiversityImprovement ||
              (replacement.diversity >= currentDiversity - materialDiversityImprovement &&
                  observation.quality >= replacedQuality + qualityReplacementMargin) else {
            return false
        }
        references[replacement.index] = observation
        return true
    }

    private static func isCompatible(_ lhs: LocalFaceEmbedding, _ rhs: LocalFaceEmbedding) -> Bool {
        lhs.modelID == rhs.modelID &&
            lhs.modelRevision == rhs.modelRevision &&
            lhs.values.count == rhs.values.count
    }

    private static func minimumPairwiseDiversity(_ references: [LocalFaceEmbedding]) -> Double {
        guard references.count > 1 else { return 1 }
        var greatestSimilarity = -1.0
        for left in references.indices {
            for right in references.indices where right > left {
                guard let similarity = try? references[left].cosineSimilarity(to: references[right]) else {
                    return 0
                }
                greatestSimilarity = max(greatestSimilarity, similarity)
            }
        }
        return max(0, 1 - greatestSimilarity)
    }
}

/// References belong only to identities that were explicitly confirmed and
/// enrolled. Recognition can recover this entity ID; it cannot create a name,
/// relationship, or consent state from appearance.
public struct LocalFaceIdentityProfile: Codable, Equatable, Sendable {
    public let entityID: UUID
    public let consentScope: IdentityConsentScope
    public let references: [LocalFaceEmbedding]

    public init(
        entityID: UUID,
        consentScope: IdentityConsentScope,
        references: [LocalFaceEmbedding]
    ) throws {
        guard consentScope != .none,
              (2 ... 24).contains(references.count),
              let first = references.first,
              references.allSatisfy({
                  $0.modelID == first.modelID
                      && $0.modelRevision == first.modelRevision
                      && $0.values.count == first.values.count
              }) else {
            throw FaceIdentityError.invalidProfile
        }
        self.entityID = entityID
        self.consentScope = consentScope
        self.references = references
    }

    private enum CodingKeys: String, CodingKey {
        case entityID, consentScope, references
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                entityID: container.decode(UUID.self, forKey: .entityID),
                consentScope: container.decode(IdentityConsentScope.self, forKey: .consentScope),
                references: container.decode([LocalFaceEmbedding].self, forKey: .references)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .references,
                in: container,
                debugDescription: "Invalid local face identity profile"
            )
        }
    }
}

public enum FaceIdentityProfileStoreError: Error, Equatable, Sendable {
    case corruptStore
    case tooManyProfiles
}

private struct FaceIdentityProfileEnvelope: Codable {
    let schemaVersion: Int
    let algorithm: String
    let ciphertext: String
}

private struct FaceIdentityProfileSnapshot: Codable {
    let schemaVersion: Int
    let profiles: [LocalFaceIdentityProfile]
}

/// Encrypted local storage for consented recognition references. The caller
/// owns root-key provisioning; neither embeddings nor the key are written to
/// traces, remote context, or the cognitive-memory journal.
public actor FaceIdentityProfileStore {
    public static let currentSchemaVersion = 1
    public static let maximumProfiles = 256

    private let fileURL: URL
    private let key: SymmetricKey
    private var profilesByEntity: [UUID: LocalFaceIdentityProfile]

    public init(fileURL: URL, encryptionKey: CognitiveMemoryEncryptionKey) throws {
        self.fileURL = fileURL
        key = SymmetricKey(data: encryptionKey.rawRepresentation)
        profilesByEntity = try Self.load(fileURL: fileURL, key: key)
    }

    public func profiles() -> [LocalFaceIdentityProfile] {
        profilesByEntity.values.sorted { $0.entityID.uuidString < $1.entityID.uuidString }
    }

    public func profile(for entityID: UUID) -> LocalFaceIdentityProfile? {
        profilesByEntity[entityID]
    }

    public func upsert(_ profile: LocalFaceIdentityProfile) throws {
        if profilesByEntity[profile.entityID] == nil,
           profilesByEntity.count >= Self.maximumProfiles {
            throw FaceIdentityProfileStoreError.tooManyProfiles
        }
        profilesByEntity[profile.entityID] = profile
        try persist()
    }

    /// Extends a persistent, explicitly enrolled profile with a distinct local
    /// observation. Session-scoped profiles are intentionally not changed.
    /// Returns the new reference count only when the retained set changed.
    public func retainPersistentObservation(
        entityID: UUID,
        embedding: LocalFaceEmbedding
    ) throws -> Int? {
        guard let profile = profilesByEntity[entityID],
              profile.consentScope == .persistent else {
            return nil
        }
        var references = profile.references
        guard LocalFaceReferenceSet.retain(
            embedding,
            in: &references,
            maximumCount: 24
        ) else {
            return nil
        }
        profilesByEntity[entityID] = try LocalFaceIdentityProfile(
            entityID: profile.entityID,
            consentScope: profile.consentScope,
            references: references
        )
        try persist()
        return references.count
    }

    public func remove(entityID: UUID) throws {
        guard profilesByEntity.removeValue(forKey: entityID) != nil else { return }
        try persist()
    }

    private func persist() throws {
        let snapshot = FaceIdentityProfileSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            profiles: profiles()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw FaceIdentityProfileStoreError.corruptStore
        }
        let envelope = FaceIdentityProfileEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            algorithm: "AES.GCM.256",
            ciphertext: combined.base64EncodedString()
        )
        let data = try encoder.encode(envelope)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func load(
        fileURL: URL,
        key: SymmetricKey
    ) throws -> [UUID: LocalFaceIdentityProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= 16 * 1_048_576 else {
                throw FaceIdentityProfileStoreError.corruptStore
            }
            let envelope = try JSONDecoder().decode(FaceIdentityProfileEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.currentSchemaVersion,
                  envelope.algorithm == "AES.GCM.256",
                  let combined = Data(base64Encoded: envelope.ciphertext) else {
                throw FaceIdentityProfileStoreError.corruptStore
            }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
            let snapshot = try JSONDecoder().decode(FaceIdentityProfileSnapshot.self, from: plaintext)
            guard snapshot.schemaVersion == Self.currentSchemaVersion,
                  snapshot.profiles.count <= Self.maximumProfiles,
                  Set(snapshot.profiles.map(\.entityID)).count == snapshot.profiles.count else {
                throw FaceIdentityProfileStoreError.corruptStore
            }
            return Dictionary(uniqueKeysWithValues: snapshot.profiles.map { ($0.entityID, $0) })
        } catch let error as FaceIdentityProfileStoreError {
            throw error
        } catch {
            throw FaceIdentityProfileStoreError.corruptStore
        }
    }
}

public struct FaceIdentityCalibration: Equatable, Sendable {
    public let minimumCosineSimilarity: Double
    public let minimumBestAlternativeMargin: Double
    public let minimumObservationQuality: Double
    public let confirmationsRequired: Int
    public let evidenceWindowMilliseconds: UInt64

    public init(
        minimumCosineSimilarity: Double,
        minimumBestAlternativeMargin: Double,
        minimumObservationQuality: Double,
        confirmationsRequired: Int = 3,
        evidenceWindowMilliseconds: UInt64 = 700
    ) throws {
        guard minimumCosineSimilarity.isFinite,
              (-1 ... 1).contains(minimumCosineSimilarity),
              minimumBestAlternativeMargin.isFinite,
              (0 ... 2).contains(minimumBestAlternativeMargin),
              minimumObservationQuality.isFinite,
              (0 ... 1).contains(minimumObservationQuality),
              (2 ... 12).contains(confirmationsRequired),
              evidenceWindowMilliseconds > 0 else {
            throw FaceIdentityError.invalidCalibration
        }
        self.minimumCosineSimilarity = minimumCosineSimilarity
        self.minimumBestAlternativeMargin = minimumBestAlternativeMargin
        self.minimumObservationQuality = minimumObservationQuality
        self.confirmationsRequired = confirmationsRequired
        self.evidenceWindowMilliseconds = evidenceWindowMilliseconds
    }
}

public enum FaceIdentityDecision: Equatable, Sendable {
    case unknown
    case candidate(entityID: UUID, similarity: Double, alternativeMargin: Double)
    case recognized(entityID: UUID, similarity: Double, alternativeMargin: Double, confirmations: Int)

    public var entityID: UUID? {
        switch self {
        case .unknown: nil
        case let .candidate(entityID, _, _), let .recognized(entityID, _, _, _): entityID
        }
    }

    public var isRecognized: Bool {
        if case .recognized = self { return true }
        return false
    }
}

/// Open-set matcher: a weak match or a close second-best identity remains
/// unknown. A recognized result additionally requires repeated agreement over
/// time, preventing one camera frame from assigning person memory.
public struct FaceIdentityMatcher: Sendable {
    public let calibration: FaceIdentityCalibration
    private var evidence: [(entityID: UUID, observedNS: UInt64)] = []

    public init(calibration: FaceIdentityCalibration) {
        self.calibration = calibration
    }

    public mutating func match(
        _ observation: LocalFaceEmbedding,
        profiles: [LocalFaceIdentityProfile],
        at monotonicNS: UInt64
    ) -> FaceIdentityDecision {
        expireEvidence(at: monotonicNS)
        guard observation.quality >= calibration.minimumObservationQuality else {
            return .unknown
        }
        let scores = profiles.compactMap { profile -> (UUID, Double)? in
            let compatible = profile.references.filter {
                $0.modelID == observation.modelID
                    && $0.modelRevision == observation.modelRevision
                    && $0.values.count == observation.values.count
            }
            guard !compatible.isEmpty else { return nil }
            let similarities = compatible.compactMap { try? observation.cosineSimilarity(to: $0) }
            guard let similarity = similarities.max() else { return nil }
            return (profile.entityID, similarity)
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first else { return .unknown }
        let alternative = scores.dropFirst().first?.1 ?? -1
        let margin = best.1 - alternative
        guard best.1 >= calibration.minimumCosineSimilarity,
              margin >= calibration.minimumBestAlternativeMargin else {
            return .unknown
        }
        if let previous = evidence.last, previous.entityID != best.0 {
            evidence.removeAll(keepingCapacity: true)
        }
        evidence.append((best.0, monotonicNS))
        let confirmations = evidence.count { $0.entityID == best.0 }
        guard confirmations >= calibration.confirmationsRequired else {
            return .candidate(entityID: best.0, similarity: best.1, alternativeMargin: margin)
        }
        return .recognized(
            entityID: best.0,
            similarity: best.1,
            alternativeMargin: margin,
            confirmations: confirmations
        )
    }

    public mutating func reset() {
        evidence.removeAll(keepingCapacity: true)
    }

    private mutating func expireEvidence(at monotonicNS: UInt64) {
        let windowNS = calibration.evidenceWindowMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !windowNS.overflow else { return }
        evidence.removeAll {
            monotonicNS < $0.observedNS || monotonicNS - $0.observedNS > windowNS.partialValue
        }
    }
}

public enum L1SocialAction: String, Codable, Hashable, Sendable {
    case remainSilent = "remain_silent"
    case nonverbalInvitation = "nonverbal_invitation"
    case spokenOpening = "spoken_opening"
}

public enum ProactiveOpeningContent: Codable, Equatable, Sendable {
    case greeting
    case question(motiveID: UUID, text: String)
}

public struct KnownPersonContactTiming: Equatable, Sendable {
    public let identityStabilityMilliseconds: UInt64
    public let minimumOpeningDelayMilliseconds: UInt64
    public let maximumOpeningDelayMilliseconds: UInt64
    public let absenceResetsPresenceMilliseconds: UInt64
    public let repeatCooldownMilliseconds: UInt64

    public init(
        identityStabilityMilliseconds: UInt64 = 600,
        minimumOpeningDelayMilliseconds: UInt64 = 500,
        maximumOpeningDelayMilliseconds: UInt64 = 2_400,
        absenceResetsPresenceMilliseconds: UInt64 = 2_000,
        repeatCooldownMilliseconds: UInt64 = 300_000
    ) {
        precondition(identityStabilityMilliseconds > 0)
        precondition(minimumOpeningDelayMilliseconds <= maximumOpeningDelayMilliseconds)
        precondition(absenceResetsPresenceMilliseconds > 0)
        precondition(repeatCooldownMilliseconds > 0)
        self.identityStabilityMilliseconds = identityStabilityMilliseconds
        self.minimumOpeningDelayMilliseconds = minimumOpeningDelayMilliseconds
        self.maximumOpeningDelayMilliseconds = maximumOpeningDelayMilliseconds
        self.absenceResetsPresenceMilliseconds = absenceResetsPresenceMilliseconds
        self.repeatCooldownMilliseconds = repeatCooldownMilliseconds
    }
}

public struct KnownPersonPresence: Equatable, Sendable {
    public let entityID: UUID
    public let recognitionConfidence: Double
    public let proactiveContactPreference: ProactiveContactPreference
    public let isSpeaking: Bool
    public let conversationActive: Bool
    public let doNotDisturb: Bool

    public init(
        entityID: UUID,
        recognitionConfidence: Double,
        proactiveContactPreference: ProactiveContactPreference = .unknown,
        isSpeaking: Bool = false,
        conversationActive: Bool = false,
        doNotDisturb: Bool = false
    ) {
        self.entityID = entityID
        self.recognitionConfidence = recognitionConfidence.isFinite
            ? min(max(recognitionConfidence, 0), 1)
            : 0
        self.proactiveContactPreference = proactiveContactPreference
        self.isSpeaking = isSpeaking
        self.conversationActive = conversationActive
        self.doNotDisturb = doNotDisturb
    }
}

/// A reason for L1 to deliberate about social action. It is context, not an
/// authorization to speak, and therefore contains the silent action as an
/// ordinary outcome.
public struct L1SocialOpportunity: Codable, Equatable, Sendable {
    public let id: UUID
    public let presenceID: UUID
    public let entityID: UUID
    public let observedAtNS: UInt64
    public let recognitionConfidence: Double
    public let availableActions: Set<L1SocialAction>
    /// Whether SOMA has already offered a nonverbal invitation during the
    /// current social cooldown. This is explicit prompt context, rather than
    /// asking the model to infer an omitted action from the action list.
    public let recentNonverbalInvitation: Bool

    public init(
        id: UUID = UUID(),
        presenceID: UUID = UUID(),
        entityID: UUID,
        observedAtNS: UInt64,
        recognitionConfidence: Double,
        availableActions: Set<L1SocialAction>,
        recentNonverbalInvitation: Bool = false
    ) {
        precondition(availableActions.contains(.remainSilent))
        self.id = id
        self.presenceID = presenceID
        self.entityID = entityID
        self.observedAtNS = observedAtNS
        self.recognitionConfidence = recognitionConfidence
        self.availableActions = availableActions
        self.recentNonverbalInvitation = recentNonverbalInvitation
    }
}

public struct L1SocialDecision: Codable, Equatable, Sendable {
    public let opportunityID: UUID
    public let entityID: UUID
    public let action: L1SocialAction
    public let confidence: Double
    public let rationale: String
    public let evidenceIDs: [String]
    public let openingContent: ProactiveOpeningContent?

    public init(
        opportunityID: UUID,
        entityID: UUID,
        action: L1SocialAction,
        confidence: Double,
        rationale: String,
        evidenceIDs: [String],
        openingContent: ProactiveOpeningContent? = nil
    ) {
        self.opportunityID = opportunityID
        self.entityID = entityID
        self.action = action
        self.confidence = confidence
        self.rationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_048))
        self.evidenceIDs = Array(evidenceIDs.prefix(128)).map { String($0.prefix(256)) }
        self.openingContent = openingContent
    }
}

/// A spoken L1 opening is a short-lived attempt to resolve one explicit
/// information need. It is intentionally separate from the broader social
/// decision: L1 can invite attention nonverbally without opening a voice
/// session, but a voice opening must carry a question and a completion target.
public struct L1PurposefulOpening: Equatable, Sendable {
    public let motiveID: UUID
    public let question: String
    public let objective: String

    public init(motiveID: UUID, question: String, objective: String) {
        self.motiveID = motiveID
        self.question = question
        self.objective = objective
    }

    public var completionCondition: String {
        "Receive one answer or a graceful decline that addresses: \(objective)"
    }
}

/// Resolves the only form of L1 decision that may create an L2 voice session.
/// A generic greeting has no answer that can reduce uncertainty, so it cannot
/// be promoted into a spoken opening.
public enum L1PurposefulOpeningGate {
    public static func resolve(
        decision: L1SocialDecision,
        informationNeeds: [L1InformationNeed]
    ) -> L1PurposefulOpening? {
        guard decision.action == .spokenOpening,
              case let .question(motiveID, question)? = decision.openingContent,
              let need = informationNeeds.first(where: { $0.motiveID == motiveID }) else {
            return nil
        }
        let objective = need.informationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return nil }
        return L1PurposefulOpening(motiveID: motiveID, question: question, objective: objective)
    }
}

public enum L1SocialDecisionError: Error, Equatable, Sendable {
    case mismatchedOpportunity
    case unavailableAction
    case staleOpportunity
    case invalidConfidence
    case missingGrounding
    case invalidOpeningContent
    case currentContextBlocksAction
}

/// The model may choose among the actions supplied by the opportunity, but
/// dispatch still rechecks current human context. This keeps recognition from
/// becoming an implicit speech command and prevents a delayed L1 response from
/// interrupting a person who has started speaking or entered do-not-disturb.
public struct L1SocialDecisionValidator: Sendable {
    public let maximumOpportunityAgeMilliseconds: UInt64

    public init(maximumOpportunityAgeMilliseconds: UInt64 = 5_000) {
        precondition(maximumOpportunityAgeMilliseconds > 0)
        self.maximumOpportunityAgeMilliseconds = maximumOpportunityAgeMilliseconds
    }

    public func validate(
        _ decision: L1SocialDecision,
        for opportunity: L1SocialOpportunity,
        currentPresence: KnownPersonPresence,
        at monotonicNS: UInt64
    ) throws {
        guard decision.opportunityID == opportunity.id,
              decision.entityID == opportunity.entityID,
              currentPresence.entityID == opportunity.entityID else {
            throw L1SocialDecisionError.mismatchedOpportunity
        }
        guard opportunity.availableActions.contains(decision.action) else {
            throw L1SocialDecisionError.unavailableAction
        }
        guard monotonicNS >= opportunity.observedAtNS,
              monotonicNS - opportunity.observedAtNS <= nanoseconds(maximumOpportunityAgeMilliseconds) else {
            throw L1SocialDecisionError.staleOpportunity
        }
        guard decision.confidence.isFinite, (0 ... 1).contains(decision.confidence) else {
            throw L1SocialDecisionError.invalidConfidence
        }
        if decision.action == .remainSilent {
            guard decision.openingContent == nil else {
                throw L1SocialDecisionError.invalidOpeningContent
            }
            return
        }
        guard !decision.rationale.isEmpty, !decision.evidenceIDs.isEmpty else {
            throw L1SocialDecisionError.missingGrounding
        }
        guard !currentPresence.doNotDisturb,
              !currentPresence.isSpeaking,
              !currentPresence.conversationActive,
              currentPresence.proactiveContactPreference != .avoid else {
            throw L1SocialDecisionError.currentContextBlocksAction
        }
        switch decision.action {
        case .spokenOpening:
            guard case .question = decision.openingContent else {
                throw L1SocialDecisionError.invalidOpeningContent
            }
        case .nonverbalInvitation:
            guard decision.openingContent == nil else {
                throw L1SocialDecisionError.invalidOpeningContent
            }
        case .remainSilent:
            break
        }
    }

    private func nanoseconds(_ milliseconds: UInt64) -> UInt64 {
        let result = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

/// Emits bounded opportunities for L1 social deliberation during a stable
/// recognized-person presence. A draw controls only when deliberation begins;
/// it never chooses speech. L1 may repeatedly conclude that silence is best.
public struct KnownPersonSocialOpportunityScheduler: Sendable {
    public let timing: KnownPersonContactTiming
    private var activeEntityID: UUID?
    private var presenceID: UUID?
    private var firstSeenNS: UInt64?
    private var lastSeenNS: UInt64?
    private var scheduledAtNS: UInt64?
    private var lastOpportunityNS: UInt64?
    private var lastInteractionByEntity: [UUID: UInt64] = [:]
    private var lastNonverbalInvitationByEntity: [UUID: UInt64] = [:]

    public init(timing: KnownPersonContactTiming = .init()) {
        self.timing = timing
    }

    public mutating func observe(
        _ presence: KnownPersonPresence?,
        at monotonicNS: UInt64,
        unitIntervalDraw: Double
    ) -> L1SocialOpportunity? {
        if presence == nil {
            if let lastSeenNS,
               monotonicNS >= lastSeenNS,
               monotonicNS - lastSeenNS >= nanoseconds(timing.absenceResetsPresenceMilliseconds) {
                clearPresence()
            }
            return nil
        }
        guard let presence else { return nil }
        if let lastSeenNS,
           monotonicNS >= lastSeenNS,
           monotonicNS - lastSeenNS >= nanoseconds(timing.absenceResetsPresenceMilliseconds) {
            clearPresence()
        }
        if activeEntityID != presence.entityID {
            beginPresence(for: presence.entityID, at: monotonicNS)
        }
        lastSeenNS = monotonicNS
        guard presence.recognitionConfidence >= 0.70,
              !presence.doNotDisturb,
              !presence.isSpeaking,
              !presence.conversationActive,
              presence.proactiveContactPreference != .avoid,
              let firstSeenNS,
              monotonicNS >= firstSeenNS + nanoseconds(timing.identityStabilityMilliseconds) else {
            return nil
        }
        if let lastInteraction = lastInteractionByEntity[presence.entityID],
           monotonicNS >= lastInteraction,
           monotonicNS - lastInteraction < nanoseconds(timing.repeatCooldownMilliseconds) {
            return nil
        }
        if scheduledAtNS == nil {
            let draw = min(max(unitIntervalDraw.isFinite ? unitIntervalDraw : 0.5, 0), 1)
            let range = timing.maximumOpeningDelayMilliseconds - timing.minimumOpeningDelayMilliseconds
            let delay = timing.minimumOpeningDelayMilliseconds + UInt64((Double(range) * draw).rounded())
            scheduledAtNS = monotonicNS + nanoseconds(delay)
        }
        guard let scheduledAtNS, monotonicNS >= scheduledAtNS else { return nil }
        if let lastOpportunityNS,
           monotonicNS >= lastOpportunityNS,
           monotonicNS - lastOpportunityNS < nanoseconds(timing.identityStabilityMilliseconds) {
            return nil
        }
        lastOpportunityNS = monotonicNS
        var actions: Set<L1SocialAction> = presence.proactiveContactPreference == .askFirst
            ? [.remainSilent, .nonverbalInvitation]
            : [.remainSilent, .nonverbalInvitation, .spokenOpening]
        let hasRecentNonverbalInvitation: Bool
        if let lastInvitation = lastNonverbalInvitationByEntity[presence.entityID],
           monotonicNS >= lastInvitation,
           monotonicNS - lastInvitation < nanoseconds(timing.repeatCooldownMilliseconds) {
            hasRecentNonverbalInvitation = true
            actions.remove(.nonverbalInvitation)
        } else {
            hasRecentNonverbalInvitation = false
        }
        // For an ask-first contact, a recent nonverbal invitation exhausts the
        // only proactive action. Do not spend another L1 cycle merely to pick
        // silence. A person who permits spoken openings remains deliberable.
        guard actions.count > 1 else { return nil }
        guard let presenceID else { return nil }
        return L1SocialOpportunity(
            presenceID: presenceID,
            entityID: presence.entityID,
            observedAtNS: monotonicNS,
            recognitionConfidence: presence.recognitionConfidence,
            availableActions: actions,
            recentNonverbalInvitation: hasRecentNonverbalInvitation
        )
    }

    public mutating func recordInteraction(with entityID: UUID, at monotonicNS: UInt64) {
        lastInteractionByEntity[entityID] = monotonicNS
    }

    public mutating func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        lastNonverbalInvitationByEntity[entityID] = monotonicNS
    }

    /// Ends the active social presence immediately after the perception layer
    /// has established a real departure or a confirmed replacement. Personal
    /// interaction history remains intact; only the active-presence schedule
    /// is cleared.
    public mutating func endPresence(for entityID: UUID) {
        guard activeEntityID == entityID else { return }
        clearPresence()
    }

    /// Rehydrates the short social cooldown after a process restart. The
    /// supplied timestamp stays in the monotonic clock used by this scheduler.
    public mutating func restoreNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        if let current = lastNonverbalInvitationByEntity[entityID], current >= monotonicNS {
            return
        }
        lastNonverbalInvitationByEntity[entityID] = monotonicNS
    }

    private mutating func beginPresence(for entityID: UUID, at monotonicNS: UInt64) {
        activeEntityID = entityID
        presenceID = UUID()
        firstSeenNS = monotonicNS
        lastSeenNS = monotonicNS
        scheduledAtNS = nil
        lastOpportunityNS = nil
    }

    private mutating func clearPresence() {
        activeEntityID = nil
        presenceID = nil
        firstSeenNS = nil
        lastSeenNS = nil
        scheduledAtNS = nil
        lastOpportunityNS = nil
    }

    private func nanoseconds(_ milliseconds: UInt64) -> UInt64 {
        let result = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
