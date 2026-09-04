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

    func testRecognitionEvidenceDoesNotCombineDifferentFaceTracks() throws {
        let person = UUID()
        let known = try profile(person, [[1, 0, 0, 0], [0.99, 0.01, 0, 0]])
        var matcher = FaceIdentityMatcher(calibration: try .init(
            minimumCosineSimilarity: 0.75,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 1_000
        ))
        let observation = try embedding([1, 0, 0, 0])
        let firstFace = UUID()
        let secondFace = UUID()

        XCTAssertFalse(matcher.match(
            observation,
            profiles: [known],
            evidenceTrackID: firstFace,
            at: 0
        ).isRecognized)
        XCTAssertFalse(matcher.match(
            observation,
            profiles: [known],
            evidenceTrackID: secondFace,
            at: 0
        ).isRecognized)
        XCTAssertFalse(matcher.match(
            observation,
            profiles: [known],
            evidenceTrackID: firstFace,
            at: 200_000_000
        ).isRecognized)
        XCTAssertFalse(matcher.match(
            observation,
            profiles: [known],
            evidenceTrackID: secondFace,
            at: 200_000_000
        ).isRecognized)

        XCTAssertTrue(matcher.match(
            observation,
            profiles: [known],
            evidenceTrackID: firstFace,
            at: 400_000_000
        ).isRecognized)
    }

    func testPeriodicRevalidationCanReconfirmBeforeMismatchGraceExpires() throws {
        let person = UUID()
        let known = try profile(person, [[1, 0, 0, 0], [0.99, 0.01, 0, 0]])
        var matcher = FaceIdentityMatcher(calibration: try .init(
            minimumCosineSimilarity: 0.75,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 1_000
        ))
        let observation = try embedding([1, 0, 0, 0])
        let trackID = UUID()
        let policy = FaceIdentityContinuityPolicy()

        XCTAssertFalse(matcher.match(observation, profiles: [known], evidenceTrackID: trackID, at: 0).isRecognized)
        XCTAssertFalse(matcher.match(observation, profiles: [known], evidenceTrackID: trackID, at: 200_000_000).isRecognized)
        XCTAssertTrue(matcher.match(observation, profiles: [known], evidenceTrackID: trackID, at: 400_000_000).isRecognized)

        let lastConfirmedNS: UInt64 = 400_000_000
        XCTAssertEqual(policy.action(for: .enrolled, lastValidatedNS: lastConfirmedNS, at: 1_400_000_000), .revalidate)
        XCTAssertFalse(matcher.match(observation, profiles: [known], evidenceTrackID: trackID, at: 1_400_000_000).isRecognized)
        XCTAssertEqual(policy.action(for: .enrolled, lastValidatedNS: lastConfirmedNS, at: 1_600_000_000), .revalidate)
        XCTAssertFalse(matcher.match(observation, profiles: [known], evidenceTrackID: trackID, at: 1_600_000_000).isRecognized)
        XCTAssertTrue(matcher.match(observation, profiles: [known], evidenceTrackID: trackID, at: 1_800_000_000).isRecognized)
        XCTAssertTrue(policy.mayBridgeMismatch(lastCorrelatedNS: lastConfirmedNS, at: 1_800_000_000))
    }

    func testRepeatedCorrelatedObservationsCanEstablishKnownIdentity() throws {
        let person = UUID()
        let known = try profile(person, [[1, 0, 0, 0], [0.99, 0.01, 0, 0]])
        var matcher = FaceIdentityMatcher(calibration: try .init(
            minimumCosineSimilarity: 0.75,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 3_000,
            correlatedConfirmationsRequired: 8,
            minimumCorrelationFloor: 0.55
        ))
        let correlated = try embedding([0.60, 0.80, 0, 0])
        let trackID = UUID()

        for index in 0..<7 {
            let result = matcher.match(
                correlated,
                profiles: [known],
                evidenceTrackID: trackID,
                at: UInt64(index) * 250_000_000
            )
            XCTAssertFalse(result.isRecognized)
        }
        let recognized = matcher.match(
            correlated,
            profiles: [known],
            evidenceTrackID: trackID,
            at: 1_750_000_000
        )
        XCTAssertEqual(recognized.entityID, person)
        XCTAssertTrue(recognized.isRecognized)
    }

    func testAmbiguousRepeatedObservationsNeverAccumulateIdentityAuthority() throws {
        let first = UUID()
        let second = UUID()
        let profiles = [
            try profile(first, [[1, 0, 0, 0], [0.99, 0.01, 0, 0]]),
            try profile(second, [[0.98, 0.20, 0, 0], [0.97, 0.24, 0, 0]]),
        ]
        var matcher = FaceIdentityMatcher(calibration: try .init(
            minimumCosineSimilarity: 0.75,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 3_000,
            correlatedConfirmationsRequired: 8,
            minimumCorrelationFloor: 0.55
        ))
        let ambiguous = try embedding([0.99, 0.10, 0, 0])
        let trackID = UUID()

        for index in 0..<12 {
            let result = matcher.match(
                ambiguous,
                profiles: profiles,
                evidenceTrackID: trackID,
                at: UInt64(index) * 200_000_000
            )
            XCTAssertFalse(result.isRecognized)
        }
    }

    func testUninformativeFrameDoesNotEraseCorrelatedIdentityEvidence() throws {
        let person = UUID()
        let known = try profile(person, [[1, 0, 0, 0], [0.99, 0.01, 0, 0]])
        var matcher = FaceIdentityMatcher(calibration: try .init(
            minimumCosineSimilarity: 0.75,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 3_000,
            correlatedConfirmationsRequired: 6,
            minimumCorrelationFloor: 0.55
        ))
        let correlated = try embedding([0.60, 0.80, 0, 0])
        let uninformative = try embedding([0, 1, 0, 0])
        let trackID = UUID()

        for index in 0..<3 {
            XCTAssertFalse(matcher.match(
                correlated,
                profiles: [known],
                evidenceTrackID: trackID,
                at: UInt64(index) * 250_000_000
            ).isRecognized)
        }
        XCTAssertFalse(matcher.match(
            uninformative,
            profiles: [known],
            evidenceTrackID: trackID,
            at: 800_000_000
        ).isRecognized)
        guard case .candidate = matcher.match(
            uninformative,
            profiles: [known],
            evidenceTrackID: trackID,
            at: 850_000_000
        ) else {
            return XCTFail("recent known evidence must continue to outrank anonymous identity")
        }
        for index in 3..<5 {
            XCTAssertFalse(matcher.match(
                correlated,
                profiles: [known],
                evidenceTrackID: trackID,
                at: UInt64(index) * 250_000_000 + 200_000_000
            ).isRecognized)
        }
        XCTAssertTrue(matcher.match(
            correlated,
            profiles: [known],
            evidenceTrackID: trackID,
            at: 1_500_000_000
        ).isRecognized)
    }

    func testDuplicateIdentityPolicyRequiresBroadMutualSimilarity() throws {
        let first = [
            try embedding([1, 0, 0, 0]),
            try embedding([0.98, 0.20, 0, 0]),
            try embedding([0.96, -0.28, 0, 0]),
        ]
        let duplicate = [
            try embedding([0.99, 0.04, 0, 0]),
            try embedding([0.97, 0.22, 0, 0]),
            try embedding([0.95, -0.30, 0, 0]),
        ]
        let oneCoincidentalMatch = [
            try embedding([1, 0, 0, 0]),
            try embedding([0, 1, 0, 0]),
            try embedding([0, 0, 1, 0]),
        ]

        XCTAssertTrue(FaceIdentityDuplicatePolicy.shouldMerge(first, duplicate))
        XCTAssertFalse(FaceIdentityDuplicatePolicy.shouldMerge(first, oneCoincidentalMatch))
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
        let first = try await registry.observe(face, at: 0, date: Date(timeIntervalSince1970: 1), persistenceApproved: true)
        let second = try await registry.observe(face, at: 100_000_000, date: Date(timeIntervalSince1970: 1.1), persistenceApproved: true)
        let third = try await registry.observe(face, at: 200_000_000, date: Date(timeIntervalSince1970: 1.2), persistenceApproved: true)
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

    func testRejectedAnonymousPromotionNeverBecomesPersistent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try AnonymousFaceRegistry(
            fileURL: directory.appendingPathComponent("anonymous.encjson"),
            encryptionKey: .generate(),
            calibration: try AnonymousFaceCalibration(
                minimumCosineSimilarity: 0.80,
                minimumBestAlternativeMargin: 0.10,
                minimumObservationQuality: 0.60,
                confirmationsRequired: 3
            )
        )
        let face = try embedding([1, 0, 0, 0])
        _ = try await registry.observe(face, at: 0, persistenceApproved: false)
        _ = try await registry.observe(face, at: 100_000_000, persistenceApproved: false)
        let rejected = try await registry.observe(face, at: 200_000_000, persistenceApproved: false)

        XCTAssertEqual(rejected, .rejected)
        let handlesAfterRejection = await registry.persistentHandles()
        XCTAssertTrue(handlesAfterRejection.isEmpty)
    }

    func testAnonymousEnrollmentEvidenceDoesNotCombineDifferentFaceTracks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-track-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try AnonymousFaceRegistry(
            fileURL: directory.appendingPathComponent("anonymous.encjson"),
            encryptionKey: .generate(),
            calibration: try AnonymousFaceCalibration(
                minimumCosineSimilarity: 0.80,
                minimumBestAlternativeMargin: 0.10,
                minimumObservationQuality: 0.60,
                confirmationsRequired: 3
            )
        )
        let face = try embedding([1, 0, 0, 0])
        let firstTrack = UUID()
        let secondTrack = UUID()

        let first = try await registry.observe(face, at: 0, persistenceApproved: true, evidenceTrackID: firstTrack)
        let other = try await registry.observe(face, at: 100_000_000, persistenceApproved: true, evidenceTrackID: secondTrack)
        let second = try await registry.observe(face, at: 200_000_000, persistenceApproved: true, evidenceTrackID: firstTrack)
        XCTAssertEqual(first, .candidate(handle: try XCTUnwrap(first.handle), confirmations: 1))
        XCTAssertEqual(other, .candidate(handle: try XCTUnwrap(other.handle), confirmations: 1))
        XCTAssertEqual(second, .candidate(handle: try XCTUnwrap(first.handle), confirmations: 2))

        let recognized = try await registry.observe(face, at: 300_000_000, persistenceApproved: true, evidenceTrackID: firstTrack)
        XCTAssertTrue(recognized.isRecognized)
    }

    func testAnonymousResetArchivesEncryptedStoreAndPreservesRecoveryCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("anonymous.encjson")
        let key = CognitiveMemoryEncryptionKey.generate()
        let calibration = try AnonymousFaceCalibration(
            minimumCosineSimilarity: 0.80,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3
        )
        var registry: AnonymousFaceRegistry? = try AnonymousFaceRegistry(
            fileURL: file,
            encryptionKey: key,
            calibration: calibration
        )
        let face = try embedding([1, 0, 0, 0])
        _ = try await registry?.observe(face, at: 0, persistenceApproved: true)
        _ = try await registry?.observe(face, at: 100_000_000, persistenceApproved: true)
        _ = try await registry?.observe(face, at: 200_000_000, persistenceApproved: true)

        XCTAssertThrowsError(try AnonymousFaceRegistry.archiveAndReset(
            fileURL: file,
            encryptionKey: key,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )) { error in
            XCTAssertEqual(error as? AnonymousFaceRegistryError, .storeLocked)
        }
        registry = nil

        let report = try AnonymousFaceRegistry.archiveAndReset(
            fileURL: file,
            encryptionKey: key,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(report.removedClusterCount, 1)
        XCTAssertNotNil(report.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(report.backupURL).path))
        let reopened = try AnonymousFaceRegistry(fileURL: file, encryptionKey: key, calibration: calibration)
        let reopenedHandles = await reopened.persistentHandles()
        XCTAssertTrue(reopenedHandles.isEmpty)
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
        _ = try await registry.observe(front, at: 0, persistenceApproved: true)
        _ = try await registry.observe(left, at: 100_000_000, persistenceApproved: true)
        let recognized = try await registry.observe(right, at: 200_000_000, persistenceApproved: true)
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

    func testRunningProfileStoreCanReloadAConsentedEnrollment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-known-reload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entityID = UUID()
        let file = directory.appendingPathComponent("profiles.encjson")
        let key = CognitiveMemoryEncryptionKey.generate()
        let runningStore = try FaceIdentityProfileStore(fileURL: file, encryptionKey: key)
        let enrollmentStore = try FaceIdentityProfileStore(fileURL: file, encryptionKey: key)
        try await enrollmentStore.upsert(try LocalFaceIdentityProfile(
            entityID: entityID,
            consentScope: .persistent,
            references: [embedding([1, 0, 0, 0]), embedding([0.98, 0.02, 0, 0])]
        ))

        let profileBeforeReload = await runningStore.profile(for: entityID)
        XCTAssertNil(profileBeforeReload)
        try await runningStore.reloadFromDisk()
        let profileAfterReload = await runningStore.profile(for: entityID)
        XCTAssertEqual(profileAfterReload?.references.count, 2)
    }

    func testExplicitEnrollmentMergeUpdatesExistingIdentityWithoutCreatingAnotherProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-known-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entityID = UUID()
        let file = directory.appendingPathComponent("profiles.encjson")
        let key = CognitiveMemoryEncryptionKey.generate()
        var store: FaceIdentityProfileStore? = try FaceIdentityProfileStore(
            fileURL: file,
            encryptionKey: key
        )
        try await store?.upsert(try LocalFaceIdentityProfile(
            entityID: entityID,
            consentScope: .persistent,
            references: [
                try embedding([1, 0, 0, 0]),
                try embedding([0.95, 0.31, 0, 0]),
            ]
        ))
        store = nil

        let count = try FaceIdentityProfileStore.mergePersistentEnrollment(
            fileURL: file,
            encryptionKey: key,
            entityID: entityID,
            references: [
                try embedding([0.95, -0.31, 0, 0]),
                try embedding([0.95, 0, 0.31, 0]),
            ]
        )
        let reopened = try FaceIdentityProfileStore(fileURL: file, encryptionKey: key)
        let profiles = await reopened.profiles()

        XCTAssertEqual(profiles.map(\.entityID), [entityID])
        XCTAssertEqual(count, 4)
        XCTAssertEqual(profiles.first?.references.count, 4)
    }

    func testExplicitEnrollmentMergeRejectsMissingDestinationAndActiveRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-known-merge-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.encjson")
        let key = CognitiveMemoryEncryptionKey.generate()
        let entityID = UUID()
        var store: FaceIdentityProfileStore? = try FaceIdentityProfileStore(
            fileURL: file,
            encryptionKey: key
        )
        try await store?.upsert(try LocalFaceIdentityProfile(
            entityID: entityID,
            consentScope: .persistent,
            references: [
                try embedding([1, 0, 0, 0]),
                try embedding([0.95, 0.31, 0, 0]),
            ]
        ))
        let enrollment = [
            try embedding([0.95, -0.31, 0, 0]),
            try embedding([0.95, 0, 0.31, 0]),
        ]

        XCTAssertThrowsError(try FaceIdentityProfileStore.mergePersistentEnrollment(
            fileURL: file,
            encryptionKey: key,
            entityID: entityID,
            references: enrollment
        )) { error in
            XCTAssertEqual(error as? FaceIdentityProfileStoreError, .storeLocked)
        }
        store = nil

        XCTAssertThrowsError(try FaceIdentityProfileStore.mergePersistentEnrollment(
            fileURL: file,
            encryptionKey: key,
            entityID: UUID(),
            references: enrollment
        )) { error in
            XCTAssertEqual(error as? FaceIdentityProfileStoreError, .profileNotFound)
        }
        let reopened = try FaceIdentityProfileStore(fileURL: file, encryptionKey: key)
        let profiles = await reopened.profiles()
        XCTAssertEqual(profiles.map(\.entityID), [entityID])
    }

    func testAnonymousEnrollmentConsumptionIsAtomicOnDestinationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-anonymous-consume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("anonymous.encjson")
        let key = CognitiveMemoryEncryptionKey.generate()
        let calibration = try AnonymousFaceCalibration(
            minimumCosineSimilarity: 0.80,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.60,
            confirmationsRequired: 3,
            maximumReferencesPerCluster: 4
        )
        var registry: AnonymousFaceRegistry? = try AnonymousFaceRegistry(
            fileURL: file,
            encryptionKey: key,
            calibration: calibration
        )
        let trackID = UUID()
        _ = try await registry?.observe(
            try embedding([1, 0, 0, 0]),
            at: 0,
            persistenceApproved: true,
            evidenceTrackID: trackID
        )
        _ = try await registry?.observe(
            try embedding([0.94, 0.34, 0, 0]),
            at: 100_000_000,
            persistenceApproved: true,
            evidenceTrackID: trackID
        )
        let recognized = try await registry?.observe(
            try embedding([0.94, -0.34, 0, 0]),
            at: 200_000_000,
            persistenceApproved: true,
            evidenceTrackID: trackID
        )
        let handle = try XCTUnwrap(recognized?.handle)

        XCTAssertThrowsError(try AnonymousFaceRegistry.consumeEnrollment(
            for: handle,
            fileURL: file,
            encryptionKey: key
        ) { _ in () }) { error in
            XCTAssertEqual(error as? AnonymousFaceRegistryError, .storeLocked)
        }
        registry = nil

        XCTAssertThrowsError(try AnonymousFaceRegistry.consumeEnrollment(
            for: handle,
            fileURL: file,
            encryptionKey: key
        ) { _ in
            throw FaceIdentityProfileStoreError.profileNotFound
        }) { error in
            XCTAssertEqual(error as? FaceIdentityProfileStoreError, .profileNotFound)
        }
        let reopened = try AnonymousFaceRegistry(
            fileURL: file,
            encryptionKey: key,
            calibration: calibration
        )
        let remainingHandles = await reopened.persistentHandles()
        XCTAssertEqual(remainingHandles, [handle])
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

        let ungroundedMemoryNeed = L1InformationNeed(
            motiveID: motive,
            source: .retainedMemoryGap,
            informationGoal: "A model inferred an unresolved detail from a camera observation.",
            expectedInformationGain: 0.98
        )
        XCTAssertNil(
            L1PurposefulOpeningGate.resolve(
                decision: question,
                informationNeeds: [ungroundedMemoryNeed]
            )
        )

        let participantFollowUpNeed = L1InformationNeed(
            motiveID: motive,
            source: .conversationFollowUp,
            informationGoal: "Follow up on an unresolved detail the participant raised earlier.",
            expectedInformationGain: 0.82
        )
        XCTAssertEqual(
            L1PurposefulOpeningGate.resolve(
                decision: question,
                informationNeeds: [participantFollowUpNeed]
            )?.motiveID,
            motive
        )
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
