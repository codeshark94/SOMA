#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class KnownPersonContactTests: XCTestCase {
    func testIdentityPresenceDistinguishesTransientMismatchReplacementAndDeparture() {
        let first = IdentityPresenceIdentity(entityID: UUID(), kind: .enrolled)
        let second = IdentityPresenceIdentity(entityID: UUID(), kind: .pseudonymous)
        var tracker = IdentityPresenceTracker(timing: .init(
            departureAfterMilliseconds: 2_500,
            replacementEvidenceWindowMilliseconds: 900,
            replacementConfirmationsRequired: 2
        ))

        XCTAssertEqual(tracker.observe(first, at: 0), [.arrived(first)])
        XCTAssertEqual(
            tracker.observe(second, at: 200_000_000),
            [.replacementCandidate(previous: first, candidate: second, confirmations: 1)]
        )
        XCTAssertEqual(tracker.observe(first, at: 400_000_000), [])
        XCTAssertEqual(tracker.currentIdentity, first)

        XCTAssertEqual(
            tracker.observe(second, at: 600_000_000),
            [.replacementCandidate(previous: first, candidate: second, confirmations: 1)]
        )
        XCTAssertEqual(
            tracker.observe(second, at: 800_000_000),
            [.replaced(previous: first, current: second)]
        )
        XCTAssertEqual(tracker.currentIdentity, second)

        XCTAssertEqual(tracker.advance(at: 3_299_999_999), [])
        XCTAssertEqual(tracker.advance(at: 3_300_000_000), [.departed(second)])
        XCTAssertNil(tracker.currentIdentity)
    }

    func testFaceIdentityRequiresOpenSetMarginAndRepeatedEvidence() throws {
        let personA = UUID()
        let personB = UUID()
        let a = try profile(personA, [[1, 0, 0, 0], [0.98, 0.02, 0, 0]])
        let b = try profile(personB, [[0, 1, 0, 0], [0.02, 0.98, 0, 0]])
        var matcher = FaceIdentityMatcher(calibration: try .init(
            minimumCosineSimilarity: 0.75,
            minimumBestAlternativeMargin: 0.20,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 500
        ))
        let observation = try embedding([0.99, 0.01, 0, 0])
        XCTAssertFalse(matcher.match(observation, profiles: [a, b], at: 0).isRecognized)
        XCTAssertFalse(matcher.match(observation, profiles: [a, b], at: 100_000_000).isRecognized)
        let recognized = matcher.match(observation, profiles: [a, b], at: 200_000_000)
        XCTAssertEqual(recognized.entityID, personA)
        XCTAssertTrue(recognized.isRecognized)

        let ambiguous = try embedding([0.71, 0.70, 0, 0])
        // Below the open-set margin so it is never recognized, but still
        // correlated with a known identity above the correlation floor, so it
        // is a known candidate rather than falling through to anonymous.
        let ambiguousDecision = matcher.match(ambiguous, profiles: [a, b], at: 250_000_000)
        guard case let .candidate(entityID, similarity, margin) = ambiguousDecision else {
            return XCTFail("expected a known candidate, got \(ambiguousDecision)")
        }
        XCTAssertEqual(entityID, personA)
        XCTAssertLessThan(similarity, matcher.calibration.minimumCosineSimilarity)
        XCTAssertGreaterThanOrEqual(similarity, matcher.calibration.minimumCorrelationFloor)
        XCTAssertLessThan(margin, matcher.calibration.minimumBestAlternativeMargin)
    }

    func testUnknownFacesUseStablePerInstallOpaqueHandlesAfterConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-face-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let calibration = try AnonymousFaceCalibration(
            minimumCosineSimilarity: 0.80,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3
        )
        let file = directory.appendingPathComponent("anonymous.encjson")
        let registry = try AnonymousFaceRegistry(
            fileURL: file,
            encryptionKey: key,
            calibration: calibration
        )
        let face = try embedding([1, 0, 0, 0])
        let first = try await registry.observe(face, at: 0, date: Date(timeIntervalSince1970: 1))
        let second = try await registry.observe(face, at: 100_000_000, date: Date(timeIntervalSince1970: 1.1))
        let third = try await registry.observe(face, at: 200_000_000, date: Date(timeIntervalSince1970: 1.2))
        XCTAssertEqual(first.handle, second.handle)
        XCTAssertEqual(second.handle, third.handle)
        XCTAssertFalse(first.isRecognized)
        XCTAssertTrue(third.isRecognized)

        let handle = try XCTUnwrap(third.handle)
        XCTAssertTrue(handle.rawValue.hasPrefix("anon_"))
        do {
            _ = try await registry.enrollmentReferences(for: handle)
            XCTFail("One static prototype must not become a persistent profile")
        } catch let error as AnonymousFaceRegistryError {
            XCTAssertEqual(error, .insufficientEnrollmentEvidence)
        } catch {
            XCTFail("Unexpected enrollment-reference error: \(error)")
        }
        let unknownHandle = try AnonymousFaceHandle(rawValue: "anon_00000000000000000000000000000000")
        do {
            _ = try await registry.enrollmentReferences(for: unknownHandle)
            XCTFail("Unknown handles must not expose enrollment references")
        } catch let error as AnonymousFaceRegistryError {
            XCTAssertEqual(error, .unknownHandle)
        } catch {
            XCTFail("Unexpected enrollment-reference error: \(error)")
        }
        let ciphertext = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(ciphertext.contains(handle.rawValue))
        XCTAssertFalse(ciphertext.contains("test-face"))

        let reopened = try AnonymousFaceRegistry(
            fileURL: file,
            encryptionKey: key,
            calibration: calibration
        )
        let returning = try await reopened.observe(
            face,
            at: 300_000_000,
            date: Date(timeIntervalSince1970: 1.3)
        )
        XCTAssertEqual(returning.handle, handle)
        XCTAssertTrue(returning.isRecognized)
        try await reopened.forget(handle)
        let remaining = await reopened.persistentHandles()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRawEmbeddingHashIsNotUsedAsAnonymousIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = try AnonymousFaceCalibration(
            minimumCosineSimilarity: 0.80,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 2
        )
        let face = try embedding([1, 0, 0, 0])
        let first = try AnonymousFaceRegistry(
            fileURL: directory.appendingPathComponent("a.encjson"),
            encryptionKey: try .init(rawRepresentation: Data(repeating: 0x11, count: 32)),
            calibration: calibration
        )
        let second = try AnonymousFaceRegistry(
            fileURL: directory.appendingPathComponent("b.encjson"),
            encryptionKey: try .init(rawRepresentation: Data(repeating: 0x22, count: 32)),
            calibration: calibration
        )
        let firstHandle = try await first.observe(face, at: 0).handle
        let secondHandle = try await second.observe(face, at: 0).handle
        XCTAssertNotEqual(firstHandle, secondHandle)
    }

    func testAnonymousClusterRetainsDistinctViewsForLaterEnrollment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-multiview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try AnonymousFaceRegistry(
            fileURL: directory.appendingPathComponent("anonymous.encjson"),
            encryptionKey: .generate(),
            calibration: try AnonymousFaceCalibration(
                minimumCosineSimilarity: 0.80,
                minimumBestAlternativeMargin: 0.10,
                minimumObservationQuality: 0.60,
                confirmationsRequired: 3,
                maximumReferencesPerCluster: 4
            )
        )
        let front = try embedding([1, 0, 0, 0])
        let left = try embedding([0.94, 0.34, 0, 0])
        let right = try embedding([0.94, -0.34, 0, 0])
        _ = try await registry.observe(front, at: 0)
        _ = try await registry.observe(left, at: 100_000_000)
        let recognized = try await registry.observe(right, at: 200_000_000)
        let handle = try XCTUnwrap(recognized.handle)
        let references = try await registry.enrollmentReferences(for: handle)
        XCTAssertEqual(references.count, 3)
        XCTAssertTrue(references.contains(front))
        XCTAssertTrue(references.contains(left))
        XCTAssertTrue(references.contains(right))
    }

    func testKnownPersistentProfileRetainsDistinctViewsButNotStaticDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-known-multiview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entityID = UUID()
        let front = try embedding([1, 0, 0, 0])
        let left = try embedding([0.94, 0.34, 0, 0])
        let right = try embedding([0.94, -0.34, 0, 0])
        let store = try FaceIdentityProfileStore(
            fileURL: directory.appendingPathComponent("profiles.encjson"),
            encryptionKey: .generate()
        )
        try await store.upsert(try LocalFaceIdentityProfile(
            entityID: entityID,
            consentScope: .persistent,
            references: [front, left]
        ))
        let expandedReferenceCount = try await store.retainPersistentObservation(
            entityID: entityID,
            embedding: right
        )
        let duplicateReferenceCount = try await store.retainPersistentObservation(
            entityID: entityID,
            embedding: front
        )
        let updatedProfile = await store.profile(for: entityID)
        XCTAssertEqual(expandedReferenceCount, 3)
        XCTAssertNil(duplicateReferenceCount)
        XCTAssertEqual(updatedProfile?.references.count, 3)
    }

    func testReferenceSetReplacesRedundantViewWhenAtCapacity() throws {
        var references = [
            try embedding([1, 0, 0, 0], quality: 0.90),
            try embedding([0.999, 0.045, 0, 0], quality: 0.70),
        ]
        let side = try embedding([0.80, 0.60, 0, 0], quality: 0.85)
        XCTAssertTrue(LocalFaceReferenceSet.retain(side, in: &references, maximumCount: 2))
        XCTAssertTrue(references.contains(side))
        XCTAssertFalse(references.contains { $0.quality == 0.70 })
    }

    func testConsentedFaceProfilesRemainEncryptedAndDeletable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-face-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.encjson")
        let key = CognitiveMemoryEncryptionKey.generate()
        let entity = UUID()
        let stored = try profile(entity, [[1, 0, 0, 0], [0.98, 0.02, 0, 0]])
        let store = try FaceIdentityProfileStore(fileURL: file, encryptionKey: key)
        try await store.upsert(stored)

        let ciphertext = try Data(contentsOf: file)
        let plaintext = String(decoding: ciphertext, as: UTF8.self)
        XCTAssertFalse(plaintext.contains(entity.uuidString))
        XCTAssertFalse(plaintext.contains("test-face"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reopened = try FaceIdentityProfileStore(fileURL: file, encryptionKey: key)
        let reopenedProfile = await reopened.profile(for: entity)
        XCTAssertEqual(reopenedProfile, stored)
        try await reopened.remove(entityID: entity)
        let removedProfile = await reopened.profile(for: entity)
        XCTAssertNil(removedProfile)

        XCTAssertThrowsError(try FaceIdentityProfileStore(
            fileURL: file,
            encryptionKey: .generate()
        )) { error in
            XCTAssertEqual(error as? FaceIdentityProfileStoreError, .corruptStore)
        }
    }

    func testKnownPersonArrivalCreatesDeliberationOpportunityNotSpeech() {
        let person = UUID()
        var scheduler = KnownPersonSocialOpportunityScheduler(timing: .init(
            identityStabilityMilliseconds: 600,
            minimumOpeningDelayMilliseconds: 500,
            maximumOpeningDelayMilliseconds: 2_500,
            absenceResetsPresenceMilliseconds: 2_000
        ))
        let presence = KnownPersonPresence(entityID: person, recognitionConfidence: 0.92)
        XCTAssertNil(scheduler.observe(presence, at: 0, unitIntervalDraw: 0.5))
        XCTAssertNil(scheduler.observe(presence, at: 600_000_000, unitIntervalDraw: 0.5))
        XCTAssertNil(scheduler.observe(presence, at: 2_099_000_000, unitIntervalDraw: 0.5))
        let opportunity = scheduler.observe(presence, at: 2_100_000_000, unitIntervalDraw: 0.5)
        XCTAssertEqual(opportunity?.entityID, person)
        XCTAssertEqual(
            opportunity?.availableActions,
            [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        XCTAssertNotNil(scheduler.observe(presence, at: 2_800_000_000, unitIntervalDraw: 0))
    }

    func testSchedulerLeavesRepeatedContactChoiceToL1Context() {
        let person = UUID()
        var scheduler = KnownPersonSocialOpportunityScheduler(timing: .init(
            identityStabilityMilliseconds: 100,
            minimumOpeningDelayMilliseconds: 0,
            maximumOpeningDelayMilliseconds: 0,
            absenceResetsPresenceMilliseconds: 2_000
        ))
        let presence = KnownPersonPresence(entityID: person, recognitionConfidence: 0.92)

        XCTAssertNil(scheduler.observe(presence, at: 0, unitIntervalDraw: 0))
        XCTAssertNotNil(scheduler.observe(presence, at: 100_000_000, unitIntervalDraw: 0))
        let afterGreeting = scheduler.observe(presence, at: 1_000_000_000, unitIntervalDraw: 0)
        XCTAssertEqual(afterGreeting?.availableActions, [.remainSilent, .nonverbalInvitation, .spokenOpening])
    }

    func testShortDetectorGapDoesNotCreateANewArrival() {
        let person = UUID()
        var scheduler = KnownPersonSocialOpportunityScheduler(timing: .init(
            identityStabilityMilliseconds: 100,
            minimumOpeningDelayMilliseconds: 0,
            maximumOpeningDelayMilliseconds: 0,
            absenceResetsPresenceMilliseconds: 2_000
        ))
        let presence = KnownPersonPresence(entityID: person, recognitionConfidence: 0.95)
        XCTAssertNil(scheduler.observe(presence, at: 0, unitIntervalDraw: 0))
        let first = scheduler.observe(presence, at: 100_000_000, unitIntervalDraw: 0)
        XCTAssertNotNil(first)
        XCTAssertNil(scheduler.observe(nil, at: 1_000_000_000, unitIntervalDraw: 0))
        let afterShortGap = scheduler.observe(presence, at: 1_100_000_000, unitIntervalDraw: 0)
        XCTAssertEqual(afterShortGap?.presenceID, first?.presenceID)
        XCTAssertNil(scheduler.observe(nil, at: 3_200_000_000, unitIntervalDraw: 0))
        XCTAssertNil(scheduler.observe(presence, at: 3_300_000_000, unitIntervalDraw: 0))
        let afterLongGap = scheduler.observe(presence, at: 3_400_000_000, unitIntervalDraw: 0)
        XCTAssertNotNil(afterLongGap)
        XCTAssertNotEqual(afterLongGap?.presenceID, first?.presenceID)
    }

    func testLongUnobservedGapBeginsANewPresenceWithoutAnExplicitMissTick() {
        let person = UUID()
        var scheduler = KnownPersonSocialOpportunityScheduler(timing: .init(
            identityStabilityMilliseconds: 100,
            minimumOpeningDelayMilliseconds: 0,
            maximumOpeningDelayMilliseconds: 0,
            absenceResetsPresenceMilliseconds: 500
        ))
        let presence = KnownPersonPresence(entityID: person, recognitionConfidence: 0.95)
        XCTAssertNil(scheduler.observe(presence, at: 0, unitIntervalDraw: 0))
        let first = scheduler.observe(presence, at: 100_000_000, unitIntervalDraw: 0)
        XCTAssertNotNil(first)
        XCTAssertNil(scheduler.observe(presence, at: 700_000_000, unitIntervalDraw: 0))
        let second = scheduler.observe(presence, at: 800_000_000, unitIntervalDraw: 0)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.presenceID, second?.presenceID)
    }

    func testContactPreferenceConstrainsAvailableActionsWithoutChoosingOne() {
        let person = UUID()
        let timing = KnownPersonContactTiming(
            identityStabilityMilliseconds: 100,
            minimumOpeningDelayMilliseconds: 0,
            maximumOpeningDelayMilliseconds: 0,
            absenceResetsPresenceMilliseconds: 500
        )
        var scheduler = KnownPersonSocialOpportunityScheduler(timing: timing)
        XCTAssertNil(scheduler.observe(.init(
            entityID: person,
            recognitionConfidence: 0.9,
            proactiveContactPreference: .allowed,
            isSpeaking: true
        ), at: 0, unitIntervalDraw: 0))
        XCTAssertNil(scheduler.observe(.init(
            entityID: person,
            recognitionConfidence: 0.9,
            proactiveContactPreference: .allowed,
            isSpeaking: true
        ), at: 100_000_000, unitIntervalDraw: 0))
        XCTAssertEqual(scheduler.observe(.init(
            entityID: person,
            recognitionConfidence: 0.9,
            proactiveContactPreference: .allowed
        ), at: 200_000_000, unitIntervalDraw: 0)?.availableActions,
        [.remainSilent, .nonverbalInvitation, .spokenOpening])

        var invitation = KnownPersonSocialOpportunityScheduler(timing: timing)
        _ = invitation.observe(.init(
            entityID: person,
            recognitionConfidence: 0.9,
            proactiveContactPreference: .askFirst
        ), at: 0, unitIntervalDraw: 0)
        XCTAssertEqual(invitation.observe(.init(
            entityID: person,
            recognitionConfidence: 0.9,
            proactiveContactPreference: .askFirst
        ), at: 100_000_000, unitIntervalDraw: 0)?.availableActions,
        [.remainSilent, .nonverbalInvitation])
    }

    func testL1MayChooseSilenceAndIdentityOpportunityAloneCannotOpenVoice() throws {
        let person = UUID()
        let opportunity = L1SocialOpportunity(
            id: UUID(),
            entityID: person,
            observedAtNS: 1_000_000_000,
            recognitionConfidence: 0.94,
            availableActions: [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        let decision = L1SocialDecision(
            opportunityID: opportunity.id,
            entityID: person,
            action: .remainSilent,
            confidence: 0.82,
            rationale: "No useful or socially appropriate interruption is present.",
            evidenceIDs: ["presence:1"]
        )
        XCTAssertNoThrow(try L1SocialDecisionValidator().validate(
            decision,
            for: opportunity,
            currentPresence: .init(entityID: person, recognitionConfidence: 0.94),
            at: 1_100_000_000
        ))

        let ungroundedSpeech = L1SocialDecision(
            opportunityID: opportunity.id,
            entityID: person,
            action: .spokenOpening,
            confidence: 0.9,
            rationale: "",
            evidenceIDs: [],
            openingContent: .greeting
        )
        XCTAssertThrowsError(try L1SocialDecisionValidator().validate(
            ungroundedSpeech,
            for: opportunity,
            currentPresence: .init(entityID: person, recognitionConfidence: 0.94),
            at: 1_100_000_000
        )) { error in
            XCTAssertEqual(error as? L1SocialDecisionError, .missingGrounding)
        }
    }

    func testPurposefulOpeningRequiresCurrentInformationNeedAndQuestion() {
        let person = UUID()
        let motive = UUID()
        let need = L1InformationNeed(
            motiveID: motive,
            source: .initialSocialOrientation,
            informationGoal: "Learn whether a proactive spoken opening is welcome now.",
            expectedInformationGain: 0.7
        )
        let question = L1SocialDecision(
            opportunityID: UUID(),
            entityID: person,
            action: .spokenOpening,
            confidence: 0.8,
            rationale: "The person is present and available.",
            evidenceIDs: ["presence:1"],
            openingContent: .question(motiveID: motive, text: "제가 먼저 말을 걸어도 괜찮을까요?")
        )
        let resolved = L1PurposefulOpeningGate.resolve(
            decision: question,
            informationNeeds: [need]
        )
        XCTAssertEqual(resolved?.motiveID, motive)
        XCTAssertEqual(resolved?.question, "제가 먼저 말을 걸어도 괜찮을까요?")
        XCTAssertEqual(resolved?.objective, need.informationGoal)
        XCTAssertNotNil(resolved?.completionCondition)

        let greeting = L1SocialDecision(
            opportunityID: UUID(),
            entityID: person,
            action: .spokenOpening,
            confidence: 0.8,
            rationale: "The person is present and available.",
            evidenceIDs: ["presence:1"],
            openingContent: .greeting
        )
        XCTAssertNil(L1PurposefulOpeningGate.resolve(decision: greeting, informationNeeds: [need]))

        let unrelated = L1SocialDecision(
            opportunityID: UUID(),
            entityID: person,
            action: .spokenOpening,
            confidence: 0.8,
            rationale: "The person is present and available.",
            evidenceIDs: ["presence:1"],
            openingContent: .question(motiveID: UUID(), text: "제가 먼저 말을 걸어도 괜찮을까요?")
        )
        XCTAssertNil(L1PurposefulOpeningGate.resolve(decision: unrelated, informationNeeds: [need]))
    }

    func testAskFirstPreferenceRejectsSpokenL1Decision() {
        let person = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 2_000_000_000,
            recognitionConfidence: 0.9,
            availableActions: [.remainSilent, .nonverbalInvitation]
        )
        let speech = L1SocialDecision(
            opportunityID: opportunity.id,
            entityID: person,
            action: .spokenOpening,
            confidence: 0.8,
            rationale: "A greeting fits the current social context.",
            evidenceIDs: ["situation:1"],
            openingContent: .greeting
        )
        XCTAssertThrowsError(try L1SocialDecisionValidator().validate(
            speech,
            for: opportunity,
            currentPresence: .init(
                entityID: person,
                recognitionConfidence: 0.9,
                proactiveContactPreference: .askFirst
            ),
            at: 2_100_000_000
        )) { error in
            XCTAssertEqual(error as? L1SocialDecisionError, .unavailableAction)
        }
    }

    private func embedding(_ values: [Float], quality: Double = 0.9) throws -> LocalFaceEmbedding {
        // Repeat the compact test direction to meet the production vector's
        // minimum dimension without changing its cosine geometry.
        try LocalFaceEmbedding(
            modelID: "test-face",
            modelRevision: 1,
            quality: quality,
            values: Array(repeating: values, count: 8).flatMap { $0 }
        )
    }

    private func profile(_ id: UUID, _ values: [[Float]]) throws -> LocalFaceIdentityProfile {
        try LocalFaceIdentityProfile(
            entityID: id,
            consentScope: .persistent,
            references: try values.map { try embedding($0) }
        )
    }
}
#endif
