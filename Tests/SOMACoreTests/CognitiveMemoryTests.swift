#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class CognitiveMemoryTests: XCTestCase {
    private let keyData = Data((0 ..< 32).map(UInt8.init))

    func testEncryptedJournalPersistsTypedMemoryWithoutPlaintext() async throws {
        let directory = temporaryDirectory("persistence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let now = Date(timeIntervalSince1970: 1_000)
        let personID = UUID()
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let record = try await store.insert(
            CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: "Known collaborator prefers concise status updates",
                payload: .personFact(
                    PersonFactMemory(personEntityID: personID, key: "communication_style", value: "concise")
                ),
                confidence: 1,
                provenance: [explicitProvenance(at: now)],
                sensitivity: .personal,
                disclosure: .remoteSummaryAllowed,
                expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
            ),
            at: now
        )
        try await store.close()

        let journalURL = directory.appendingPathComponent(CognitiveMemoryStore.journalFilename)
        let journal = try Data(contentsOf: journalURL)
        XCTAssertFalse(String(decoding: journal, as: UTF8.self).contains(record.summary))
        XCTAssertEqual(try permissions(journalURL), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)

        let reopened = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let restored = try await reopened.record(id: record.id, at: now)
        XCTAssertEqual(restored, record)
        let related = try await reopened.query(.init(relatedTo: [personID]), at: now)
        XCTAssertEqual(related.map(\.id), [record.id])
        try await reopened.close()
    }

    func testCorrectionPromotionAndDeletionLifecycle() async throws {
        let directory = temporaryDirectory("lifecycle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let start = Date(timeIntervalSince1970: 2_000)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let initial = try await store.insert(
            taskDraft(
                summary: "Prepare memory contract",
                status: .planned,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60 * 60),
                at: start
            ),
            at: start
        )
        let correctedAt = start.addingTimeInterval(60)
        let corrected = try await store.correct(
            id: initial.id,
            replacement: taskDraft(
                summary: "Memory contract implementation is active",
                status: .active,
                tier: .shortTerm,
                expiresAt: correctedAt.addingTimeInterval(60 * 60),
                at: correctedAt
            ),
            reason: "task started",
            at: correctedAt
        )
        XCTAssertEqual(corrected.revision, 2)
        let correctedHistory = try await store.history(id: initial.id)
        XCTAssertEqual(correctedHistory.map(\.revision), [1, 2])

        let promotedAt = start.addingTimeInterval(120)
        let promoted = try await store.promote(
            id: initial.id,
            to: .mediumTerm,
            expiresAt: promotedAt.addingTimeInterval(30 * 24 * 60 * 60),
            provenance: [
                MemoryProvenance(
                    source: .consolidation,
                    sourceID: "consolidation:test",
                    observedAt: promotedAt,
                    evidenceIDs: [initial.id.uuidString]
                )
            ],
            reason: "task remains active beyond the working situation",
            at: promotedAt
        )
        XCTAssertEqual(promoted.revision, 3)
        XCTAssertEqual(promoted.tier, .mediumTerm)

        try await store.delete(id: initial.id, reason: "user requested deletion", at: promotedAt)
        let deletedRecord = try await store.record(id: initial.id, at: promotedAt)
        let deletedHistory = try await store.history(id: initial.id)
        XCTAssertNil(deletedRecord)
        XCTAssertTrue(deletedHistory.isEmpty)
        try await store.close()

        let journalURL = directory.appendingPathComponent(CognitiveMemoryStore.journalFilename)
        XCTAssertEqual(try Data(contentsOf: journalURL).count, 0)
        let reopened = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let reopenedRecord = try await reopened.record(id: initial.id, at: promotedAt)
        XCTAssertNil(reopenedRecord)
        try await reopened.close()
    }

    func testTierExpiryAndLongTermConsolidationRules() async throws {
        let directory = temporaryDirectory("expiry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let start = Date(timeIntervalSince1970: 3_000)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let short = try await store.insert(
            CognitiveMemoryDraft(
                tier: .shortTerm,
                summary: "A person is currently near the camera",
                payload: .situation(SituationMemory(state: "person_present")),
                confidence: 0.9,
                provenance: [sensorProvenance(at: start)],
                expiresAt: start.addingTimeInterval(10)
            ),
            at: start
        )
        _ = try await store.insert(
            CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: "A short interaction occurred in the workspace",
                payload: .episode(EpisodeMemory(startedAt: start, endedAt: start.addingTimeInterval(5))),
                confidence: 0.8,
                provenance: [sensorProvenance(at: start)],
                expiresAt: start.addingTimeInterval(30 * 24 * 60 * 60)
            ),
            at: start
        )
        _ = try await store.insert(
            CognitiveMemoryDraft(
                tier: .longTerm,
                summary: "The workspace is a familiar room",
                payload: .space(SpaceMemory(name: "workspace", familiarity: 0.9)),
                confidence: 0.95,
                provenance: [explicitProvenance(at: start)]
            ),
            at: start
        )

        let expiredRecord = try await store.record(id: short.id, at: start.addingTimeInterval(11))
        XCTAssertNil(expiredRecord)
        let expired = try await store.purgeExpired(at: start.addingTimeInterval(11))
        XCTAssertEqual(expired, [short.id])
        let stats = try await store.stats(at: start.addingTimeInterval(11))
        XCTAssertEqual(stats.activeRecords, 2)
        XCTAssertEqual(stats.mediumTermRecords, 1)
        XCTAssertEqual(stats.longTermRecords, 1)

        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .longTerm,
                    summary: "An unconfirmed model guess",
                    payload: .situation(SituationMemory(state: "guess")),
                    confidence: 0.6,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1:test",
                            observedAt: start,
                            evidenceIDs: ["frame:test"]
                        )
                    ]
                ),
                at: start
            )
            XCTFail("direct L1 inference entered long-term memory")
        } catch let error as CognitiveMemoryError {
            guard case .validationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        try await store.close()
    }

    func testIdentityConsentAndRemoteProjectionBoundary() async throws {
        let directory = temporaryDirectory("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let start = Date(timeIntervalSince1970: 4_000)
        let personID = UUID()
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)

        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: "Confirmed identity",
                    payload: .identity(
                        IdentityMemory(
                            entityID: personID,
                            status: .confirmed,
                            displayName: "Person A",
                            localRecognitionReference: "embedding:keychain:1",
                            consentScope: .persistent
                        )
                    ),
                    confidence: 0.99,
                    provenance: [explicitProvenance(at: start)],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: start.addingTimeInterval(30 * 24 * 60 * 60)
                ),
                at: start
            )
            XCTFail("biometric identity escaped its local-only boundary")
        } catch let error as CognitiveMemoryError {
            guard case .validationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }

        let identity = try await store.insert(
            CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: "Confirmed local identity for Person A",
                payload: .identity(
                    IdentityMemory(
                        entityID: personID,
                        status: .confirmed,
                        displayName: "Person A",
                        localRecognitionReference: "embedding:keychain:1",
                        consentScope: .persistent
                    )
                ),
                confidence: 0.99,
                provenance: [
                    MemoryProvenance(
                        source: .identityEnrollment,
                        sourceID: "enrollment:test",
                        observedAt: start,
                        evidenceIDs: ["consent:test"]
                    )
                ],
                sensitivity: .biometric,
                disclosure: .localOnly,
                expiresAt: start.addingTimeInterval(30 * 24 * 60 * 60)
            ),
            at: start
        )
        let shareable = try await store.insert(
            CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: "Person A prefers short status summaries",
                payload: .personFact(PersonFactMemory(personEntityID: personID, key: "status_style", value: "short")),
                confidence: 1,
                provenance: [explicitProvenance(at: start)],
                sensitivity: .personal,
                disclosure: .remoteSummaryAllowed,
                expiresAt: start.addingTimeInterval(30 * 24 * 60 * 60)
            ),
            at: start
        )
        let projection = try await store.remoteProjection(.init(relatedTo: [personID]), at: start)
        XCTAssertEqual(projection.map(\.id), [shareable.id])
        XCTAssertFalse(projection.contains { $0.id == identity.id })
        try await store.close()
    }

    func testExplicitPersonContextUpdatesLanguageRapportAndFactsWithoutBiometrics() async throws {
        let directory = temporaryDirectory("person-context")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let personID = UUID()
        let start = Date(timeIntervalSince1970: 4_500)

        let first = try await store.setExplicitPersonFact(
            personEntityID: personID,
            key: "preferred_language",
            value: "zh-Hans",
            at: start
        )
        XCTAssertEqual(first.preferredLanguageTag, "zh-Hans")
        XCTAssertEqual(first.facts["preferred_language"], "zh-Hans")

        let revised = try await store.setExplicitPersonFact(
            personEntityID: personID,
            key: "preferred_language",
            value: "en-US",
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(revised.preferredLanguageTag, "en-US")
        XCTAssertEqual(revised.facts.count, 1)

        let rapport = try await store.setExplicitPersonRapport(
            personEntityID: personID,
            rapport: RapportProfile(
                familiarity: 0.7,
                interactionComfort: 0.8,
                communicationAlignment: 0.9,
                proactiveContact: .allowed
            ),
            at: start.addingTimeInterval(2)
        )
        XCTAssertEqual(rapport.proactiveContactPreference, .allowed)
        XCTAssertEqual(rapport.rapport?.communicationAlignment, 0.9)

        let removed = try await store.clearExplicitPersonFact(
            personEntityID: personID,
            key: "preferred_language",
            at: start.addingTimeInterval(3)
        )
        XCTAssertNil(removed.preferredLanguageTag)
        XCTAssertEqual(removed.proactiveContactPreference, .allowed)
        let projection = try await store.remoteProjection(.init(relatedTo: [personID]), at: start.addingTimeInterval(3))
        XCTAssertEqual(projection.count, 1)
        XCTAssertEqual(projection.first?.kind, .relationship)
        try await store.close()
    }

    func testPersonContextDerivesRapportFromReciprocalContactAndPreservesExplicitOverride() async throws {
        let directory = temporaryDirectory("social-rapport")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let personID = UUID()
        let start = Date(timeIntervalSince1970: 5_000)

        for (offset, kind) in [
            L1SocialContactKind.conversationOpened,
            .participantResponded,
            .conversationEnded,
        ].enumerated() {
            let observedAt = start.addingTimeInterval(TimeInterval(offset))
            _ = try await store.insert(
                socialContactDraft(personID: personID, kind: kind, at: observedAt),
                at: observedAt
            )
        }

        let inferred = try await store.personContext(for: personID, at: start.addingTimeInterval(3))
        XCTAssertNotNil(inferred.rapport)
        XCTAssertGreaterThan(inferred.rapport?.familiarity ?? 0, 0.2)
        XCTAssertGreaterThan(inferred.rapport?.interactionComfort ?? 0, 0.5)
        XCTAssertGreaterThan(inferred.rapport?.communicationAlignment ?? 0, 0.5)
        XCTAssertEqual(inferred.proactiveContactPreference, .unknown)

        let explicit = try await store.setExplicitPersonRapport(
            personEntityID: personID,
            rapport: RapportProfile(
                familiarity: 0.9,
                interactionComfort: 0.8,
                communicationAlignment: 0.7,
                proactiveContact: .allowed
            ),
            at: start.addingTimeInterval(4)
        )
        XCTAssertEqual(explicit.rapport?.familiarity, 0.9)
        XCTAssertEqual(explicit.rapport?.interactionComfort, 0.8)
        XCTAssertEqual(explicit.rapport?.communicationAlignment, 0.7)
        XCTAssertEqual(explicit.proactiveContactPreference, .allowed)

        let preference = try await store.setExplicitPersonFact(
            personEntityID: personID,
            key: "proactive_contact",
            value: ProactiveContactPreference.avoid.rawValue,
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(preference.rapport?.familiarity, 0.9)
        XCTAssertEqual(preference.rapport?.interactionComfort, 0.8)
        XCTAssertEqual(preference.rapport?.communicationAlignment, 0.7)
        XCTAssertEqual(preference.proactiveContactPreference, .avoid)
        try await store.close()
    }

    func testWrongKeyAndSecondWriterAreRejected() async throws {
        let directory = temporaryDirectory("locking")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let start = Date(timeIntervalSince1970: 5_000)
        _ = try await store.insert(
            taskDraft(
                summary: "Writer lock fixture",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60),
                at: start
            ),
            at: start
        )
        XCTAssertThrowsError(try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)) { error in
            XCTAssertEqual(error as? CognitiveMemoryError, .storeLocked)
        }
        try await store.close()

        let wrongKey = try CognitiveMemoryEncryptionKey(rawRepresentation: Data(repeating: 0xFF, count: 32))
        XCTAssertThrowsError(try CognitiveMemoryStore(directoryURL: directory, encryptionKey: wrongKey)) { error in
            guard case .corruptJournal = error as? CognitiveMemoryError else {
                return XCTFail("wrong key did not fail authentication: \(error)")
            }
        }
    }

    func testRecoveryStagesVerifiedPrefixWithoutChangingCorruptSourceJournal() async throws {
        let directory = temporaryDirectory("recovery-source")
        let recoveryDirectory = temporaryDirectory("recovery-candidate")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: recoveryDirectory)
        }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let start = Date(timeIntervalSince1970: 5_250)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let first = try await store.insert(
            taskDraft(
                summary: "Retain the verified first entry",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60),
                at: start
            ),
            at: start
        )
        _ = try await store.insert(
            taskDraft(
                summary: "Corrupt this entry in the fixture",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60),
                at: start.addingTimeInterval(1)
            ),
            at: start.addingTimeInterval(1)
        )
        _ = try await store.insert(
            taskDraft(
                summary: "Do not promote unverified suffix entries",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60),
                at: start.addingTimeInterval(2)
            ),
            at: start.addingTimeInterval(2)
        )
        try await store.close()

        let journalURL = directory.appendingPathComponent(CognitiveMemoryStore.journalFilename)
        let original = try Data(contentsOf: journalURL)
        let lines = original.split(separator: 0x0A, omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        var corruptLine = Data(lines[1])
        let corruptionIndex = corruptLine.index(corruptLine.startIndex, offsetBy: corruptLine.count / 2)
        corruptLine[corruptionIndex] ^= 0x01
        var corrupted = Data()
        for (index, line) in lines.enumerated() {
            corrupted.append(contentsOf: index == 1 ? corruptLine : line)
            corrupted.append(0x0A)
        }
        try corrupted.write(to: journalURL, options: .atomic)

        XCTAssertThrowsError(try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)) { error in
            XCTAssertEqual(error as? CognitiveMemoryError, .corruptJournal(line: 2))
        }

        let report = try CognitiveMemoryStore.stageRecoverablePrefix(
            from: directory,
            encryptionKey: key,
            into: recoveryDirectory
        )
        XCTAssertEqual(report.sourceEntryCount, 3)
        XCTAssertEqual(report.recoveredEntryCount, 1)
        XCTAssertEqual(report.firstRejectedLine, 2)
        XCTAssertEqual(try Data(contentsOf: journalURL), corrupted)

        let recoveredStore = try CognitiveMemoryStore(directoryURL: recoveryDirectory, encryptionKey: key)
        let recoveredFirst = try await recoveredStore.record(id: first.id, at: start)
        XCTAssertEqual(recoveredFirst, first)
        try await recoveredStore.close()
    }

    func testRecoveryActivationRestoresVerifiedPrefixAndPreservesCorruptJournal() async throws {
        let directory = temporaryDirectory("recovery-activation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let start = Date(timeIntervalSince1970: 5_500)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let first = try await store.insert(
            taskDraft(
                summary: "Keep this entry after recovery activation",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60),
                at: start
            ),
            at: start
        )
        _ = try await store.insert(
            taskDraft(
                summary: "Damage this encrypted entry",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60),
                at: start.addingTimeInterval(1)
            ),
            at: start.addingTimeInterval(1)
        )
        try await store.close()

        let journalURL = directory.appendingPathComponent(CognitiveMemoryStore.journalFilename)
        let original = try Data(contentsOf: journalURL)
        let lines = original.split(separator: 0x0A, omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        var corruptLine = Data(lines[1])
        let corruptionIndex = corruptLine.index(corruptLine.startIndex, offsetBy: corruptLine.count / 2)
        corruptLine[corruptionIndex] ^= 0x01
        var corrupted = Data(lines[0])
        corrupted.append(0x0A)
        corrupted.append(corruptLine)
        corrupted.append(0x0A)
        try corrupted.write(to: journalURL, options: .atomic)

        let recovery = try CognitiveMemoryStore.activateRecoverablePrefix(
            from: directory,
            encryptionKey: key
        )
        XCTAssertEqual(recovery.sourceEntryCount, 2)
        XCTAssertEqual(recovery.recoveredEntryCount, 1)
        XCTAssertEqual(recovery.firstRejectedLine, 2)
        XCTAssertEqual(try Data(contentsOf: recovery.backupJournalURL), corrupted)
        XCTAssertEqual(try permissions(journalURL), 0o600)
        XCTAssertEqual(try permissions(recovery.backupJournalURL), 0o600)

        let recoveredStore = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let recovered = try await recoveredStore.record(id: first.id, at: start)
        XCTAssertEqual(recovered, first)
        try await recoveredStore.close()
    }

    func testCompactionRetainsRevisionTailAsAValidReplayBaseline() async throws {
        let directory = temporaryDirectory("compacted-revision-tail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let start = Date(timeIntervalSince1970: 5_500)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let initial = try await store.insert(
            taskDraft(
                summary: "Revision-tail fixture 1",
                status: .active,
                tier: .shortTerm,
                expiresAt: start.addingTimeInterval(60 * 60),
                at: start
            ),
            at: start
        )
        var latest = initial
        for revision in 2 ... 14 {
            let updatedAt = start.addingTimeInterval(TimeInterval(revision))
            latest = try await store.correct(
                id: initial.id,
                replacement: taskDraft(
                    summary: "Revision-tail fixture \(revision)",
                    status: .active,
                    tier: .shortTerm,
                    expiresAt: updatedAt.addingTimeInterval(60 * 60),
                    at: updatedAt
                ),
                reason: "revision tail fixture update",
                at: updatedAt
            )
        }
        try await store.compact()
        try await store.close()

        let reopened = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let restored = try await reopened.record(id: initial.id, at: start.addingTimeInterval(20))
        XCTAssertEqual(restored?.revision, latest.revision)
        let nextAt = start.addingTimeInterval(30)
        let next = try await reopened.correct(
            id: initial.id,
            replacement: taskDraft(
                summary: "Revision-tail fixture 15",
                status: .active,
                tier: .shortTerm,
                expiresAt: nextAt.addingTimeInterval(60 * 60),
                at: nextAt
            ),
            reason: "revision tail continues after reopen",
            at: nextAt
        )
        XCTAssertEqual(next.revision, 15)
        try await reopened.close()
    }

    func testRawL2TurnsRemainEncryptedUntilL1Consolidation() async throws {
        let directory = temporaryDirectory("conversation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let interactionID = UUID()
        let participantID = UUID()
        let threadID = "codex-live-thread-1"
        let start = Date(timeIntervalSince1970: 6_000)
        let archiver = ConversationTranscriptArchiver(
            store: store,
            interactionID: interactionID,
            threadID: threadID,
            participantEntityIDs: [participantID]
        )
        let exactText = "Please remember that I prefer status updates after lunch."
        let raw = try await archiver.append(
            role: .user,
            rawText: exactText,
            sourceEventID: "realtime-transcript:1",
            at: start
        )
        guard case let .conversationTurn(turn) = raw.payload else {
            return XCTFail("raw transcript did not retain its typed payload")
        }
        XCTAssertEqual(turn.rawText, exactText)
        XCTAssertEqual(turn.consolidationState, .pending)
        XCTAssertEqual(turn.participantEntityIDs, [participantID])
        XCTAssertTrue(raw.relatedIDs.contains(participantID))
        let pendingBeforeConsolidation = try await archiver.pending(at: start)
        XCTAssertEqual(pendingBeforeConsolidation.map(\.id), [raw.id])

        let journal = try Data(contentsOf: directory.appendingPathComponent(CognitiveMemoryStore.journalFilename))
        XCTAssertFalse(String(decoding: journal, as: UTF8.self).contains(exactText))

        let derived = UUID()
        let consolidated = try await archiver.markConsolidated(
            recordID: raw.id,
            derivedMemoryIDs: [derived],
            at: start.addingTimeInterval(1)
        )
        guard case let .conversationTurn(consolidatedTurn) = consolidated.payload else {
            return XCTFail("consolidated transcript changed kind")
        }
        XCTAssertEqual(consolidatedTurn.rawText, exactText)
        XCTAssertEqual(consolidatedTurn.consolidationState, .consolidated)
        XCTAssertEqual(consolidatedTurn.derivedMemoryIDs, [derived])
        let pendingAfterConsolidation = try await archiver.pending(at: start.addingTimeInterval(1))
        XCTAssertTrue(pendingAfterConsolidation.isEmpty)
        try await store.close()
    }

    func testConversationTurnWriteBarrierWaitsForEveryQueuedTurn() async {
        let barrier = ConversationTurnWriteBarrier()
        barrier.beginWrite()
        barrier.beginWrite()
        XCTAssertFalse(barrier.isDrained)

        let waiter = Task {
            await barrier.waitUntilDrained()
            return true
        }
        await Task.yield()

        barrier.finishWrite()
        XCTAssertFalse(barrier.isDrained)
        barrier.finishWrite()

        let drained = await waiter.value
        XCTAssertTrue(drained)
        XCTAssertTrue(barrier.isDrained)
    }

    func testRawConversationCannotBecomeRemoteOrLongTermMemory() async throws {
        let directory = temporaryDirectory("conversation-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try CognitiveMemoryEncryptionKey(rawRepresentation: keyData)
        let store = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
        let start = Date(timeIntervalSince1970: 7_000)
        let turn = ConversationTurnMemory(
            interactionID: UUID(),
            threadID: "thread-policy",
            turnSequence: 1,
            role: .assistant,
            rawText: "A complete response transcript.",
            finalizedAt: start
        )
        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .longTerm,
                    summary: "Invalid raw transcript promotion",
                    payload: .conversationTurn(turn),
                    confidence: 1,
                    provenance: [
                        MemoryProvenance(
                            source: .l2Interaction,
                            sourceID: "codex-thread:thread-policy",
                            observedAt: start,
                            evidenceIDs: ["turn:1"]
                        ),
                        explicitProvenance(at: start),
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed
                ),
                at: start
            )
            XCTFail("raw transcript escaped short-term local retention")
        } catch let error as CognitiveMemoryError {
            guard case .validationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        try await store.close()
    }

    func testPersonContextMissionIsDerivedFromStoredFacts() {
        let personID = UUID()
        let incomplete = PersonContextSnapshot(
            personEntityID: personID,
            preferredLanguageTag: nil,
            proactiveContactPreference: .unknown,
            rapport: nil,
            facts: [:]
        )
        XCTAssertEqual(incomplete.mission.missingRequiredKeys, ["preferred_name"])
        XCTAssertFalse(incomplete.mission.isSatisfied)

        let known = PersonContextSnapshot(
            personEntityID: personID,
            preferredLanguageTag: "ko",
            proactiveContactPreference: .unknown,
            rapport: nil,
            facts: ["preferred_name": "승엽"]
        )
        XCTAssertTrue(known.mission.isSatisfied)
        XCTAssertTrue(known.mission.missingRequiredKeys.isEmpty)
        XCTAssertFalse(known.mission.recommendedKeys.contains("preferred_language"))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-memory-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func explicitProvenance(at date: Date) -> MemoryProvenance {
        MemoryProvenance(source: .explicitUser, sourceID: "user:test", observedAt: date, evidenceIDs: ["turn:test"])
    }

    private func sensorProvenance(at date: Date) -> MemoryProvenance {
        MemoryProvenance(source: .sensorSummary, sourceID: "l0:test", observedAt: date, evidenceIDs: ["event:test"])
    }

    private func taskDraft(
        summary: String,
        status: MemoryTaskStatus,
        tier: MemoryTier,
        expiresAt: Date,
        at date: Date
    ) -> CognitiveMemoryDraft {
        CognitiveMemoryDraft(
            tier: tier,
            summary: summary,
            payload: .task(TaskMemory(title: "Memory layer", status: status)),
            confidence: 1,
            provenance: [explicitProvenance(at: date)],
            expiresAt: expiresAt
        )
    }

    private func socialContactDraft(
        personID: UUID,
        kind: L1SocialContactKind,
        at date: Date
    ) -> CognitiveMemoryDraft {
        CognitiveMemoryDraft(
            tier: .mediumTerm,
            summary: "Social contact \(kind.rawValue).",
            payload: .situation(SituationMemory(
                state: "social_contact:\(kind.rawValue)",
                participantEntityIDs: [personID]
            )),
            confidence: 1,
            provenance: [MemoryProvenance(
                source: .l1Inference,
                sourceID: "l1_social_contact:test",
                observedAt: date,
                evidenceIDs: ["social:test"]
            )],
            sensitivity: .personal,
            disclosure: .remoteSummaryAllowed,
            expiresAt: date.addingTimeInterval(90 * 24 * 60 * 60)
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
#endif
