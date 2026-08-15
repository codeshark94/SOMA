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

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
#endif
