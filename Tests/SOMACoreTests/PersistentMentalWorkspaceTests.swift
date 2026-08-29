import Foundation
import XCTest
@testable import SOMACore

final class PersistentMentalWorkspaceTests: XCTestCase {
    func testRepeatedEvidenceIsIdempotentAndDoesNotAdvanceRevision() async {
        let workspace = PersistentMentalWorkspace()
        let event = MentalEvidenceEvent(
            id: "frame:1:phone",
            observedAt: Date(timeIntervalSince1970: 100),
            kind: .ordinaryObservation,
            summary: "The person remains focused on a phone.",
            confidence: 0.9,
            novelty: 0.1,
            hypothesis: MentalHypothesisSeed(
                kind: .situational,
                content: "The person is focused on a device.",
                confidence: 0.8,
                salience: 0.4
            )
        )

        let first = await workspace.ingest(event)
        let repeated = await workspace.ingest(event)

        XCTAssertTrue(first.changed)
        XCTAssertTrue(first.delta.meaningfulTransition)
        XCTAssertFalse(repeated.changed)
        XCTAssertTrue(repeated.delta.duplicateEvidence)
        XCTAssertEqual(repeated.after.revision, first.after.revision)
        XCTAssertEqual(repeated.after.hypotheses.count, 1)
    }

    func testEquivalentObservationsSupportOneHypothesisInsteadOfCreatingNarrationFrames() async {
        let workspace = PersistentMentalWorkspace()
        let start = Date(timeIntervalSince1970: 200)
        let seed = MentalHypothesisSeed(
            kind: .situational,
            content: "The person is focused on a device.",
            confidence: 0.55,
            salience: 0.4
        )
        let first = await workspace.ingest(MentalEvidenceEvent(
            id: "frame:1",
            observedAt: start,
            kind: .ordinaryObservation,
            summary: "Focused posture.",
            confidence: 0.8,
            novelty: 0.2,
            hypothesis: seed
        ))
        let supported = await workspace.ingest(MentalEvidenceEvent(
            id: "frame:2",
            observedAt: start.addingTimeInterval(2),
            kind: .ordinaryObservation,
            summary: "The same focused posture continues.",
            confidence: 0.8,
            novelty: 0.05,
            hypothesis: seed
        ))
        let visuallyDifferentButSemanticallyEquivalent = await workspace.ingest(MentalEvidenceEvent(
            id: "frame:3",
            observedAt: start.addingTimeInterval(4),
            kind: .ordinaryObservation,
            summary: "The same person and device remain present from a different frame.",
            confidence: 0.9,
            novelty: 0.95,
            hypothesis: seed
        ))

        XCTAssertEqual(supported.after.hypotheses.count, 1)
        XCTAssertGreaterThan(
            supported.after.hypotheses[0].confidence,
            first.after.hypotheses[0].confidence
        )
        XCTAssertFalse(supported.delta.meaningfulTransition)
        XCTAssertTrue(supported.delta.changedFields[0].hasPrefix("hypothesis_supported:"))
        XCTAssertEqual(supported.after.revision, first.after.revision)
        XCTAssertFalse(visuallyDifferentButSemanticallyEquivalent.delta.meaningfulTransition)
        XCTAssertLessThanOrEqual(visuallyDifferentButSemanticallyEquivalent.delta.novelty, 0.3)
        XCTAssertEqual(visuallyDifferentButSemanticallyEquivalent.after.revision, first.after.revision)
    }

    func testUnsupportedHypothesisDecaysThroughDormantToAbandoned() async {
        let start = Date(timeIntervalSince1970: 300)
        let workspace = PersistentMentalWorkspace(policy: MentalDynamicsPolicy(
            perceptualHalfLifeSeconds: 10,
            situationalHalfLifeSeconds: 10,
            socialHalfLifeSeconds: 10,
            associationHalfLifeSeconds: 10,
            curiosityHalfLifeSeconds: 10
        ))
        _ = await workspace.ingest(MentalEvidenceEvent(
            id: "gesture:1",
            observedAt: start,
            kind: .ordinaryObservation,
            summary: "A brief ambiguous gesture.",
            confidence: 0.7,
            novelty: 0.6,
            hypothesis: MentalHypothesisSeed(
                kind: .perceptual,
                content: "The person may be trying to show an object.",
                confidence: 0.7,
                salience: 0.7
            )
        ))

        let dormant = await workspace.snapshot(at: start.addingTimeInterval(12))
        XCTAssertEqual(dormant.hypotheses[0].status, .dormant)

        let abandoned = await workspace.snapshot(at: start.addingTimeInterval(30))
        XCTAssertEqual(abandoned.hypotheses[0].status, .abandoned)
    }

    func testRelationshipUncertaintyIsCanonicalAcrossEvidencePaths() async {
        let personID = UUID()
        let workspace = PersistentMentalWorkspace()
        _ = await workspace.ingest(MentalEvidenceEvent(
            id: "memory:rapport",
            kind: .memoryAssociation,
            summary: "Authoritative relationship context.",
            subjectEntityID: personID,
            confidence: 1,
            novelty: 0.4,
            contextPatch: MentalContextPatch(relationshipUncertainty: 0.12)
        ))
        _ = await workspace.ingest(MentalEvidenceEvent(
            id: "behavior:scan",
            kind: .ordinaryObservation,
            summary: "The camera is observing the same person.",
            subjectEntityID: personID,
            confidence: 0.9,
            novelty: 0.1,
            contextPatch: MentalContextPatch(
                presentEntityIDs: [personID],
                socialAvailability: 0.3
            )
        ))

        let snapshot = await workspace.snapshot()
        XCTAssertEqual(snapshot.context.relationshipUncertainty, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.context.presentEntityIDs, [personID])
    }

    func testThoughtUpdateHasNoActionAndForegroundSelectionIsSeedable() async throws {
        let workspace = PersistentMentalWorkspace(randomSeed: 42)
        let event = MentalEvidenceEvent(
            id: "memory:question",
            observedAt: Date(timeIntervalSince1970: 400),
            kind: .memoryAssociation,
            summary: "An unresolved question remains.",
            confidence: 1,
            novelty: 0.7,
            driveSignal: MentalDriveSignal(curiosity: 0.8)
        )
        let transition = await workspace.ingest(event)
        let update = L1ThoughtUpdate(
            expectedRevision: transition.after.revision,
            evidenceIDs: [event.id],
            innerMonologue: "That earlier question still matters, but I do not need to act on it yet.",
            channel: .curiosity,
            continuity: .revise,
            confidence: 0.9,
            salience: 0.8,
            novelty: 0.6
        )

        let result = try await workspace.applyThoughtUpdate(update, at: event.observedAt, draw: 0)
        XCTAssertEqual(result.after.foregroundThought?.content, update.innerMonologue)
        XCTAssertTrue(result.after.intentions.isEmpty)
        XCTAssertEqual(result.after.lastThoughtAt, event.observedAt)
    }

    func testStaleThoughtUpdateCannotOverwriteNewerWorkspace() async {
        let workspace = PersistentMentalWorkspace()
        let first = await workspace.ingest(MentalEvidenceEvent(
            id: "scene:1",
            kind: .sceneTransition,
            summary: "The scene changed.",
            confidence: 1,
            novelty: 1
        ))
        let staleUpdate = L1ThoughtUpdate(
            expectedRevision: first.after.revision,
            evidenceIDs: ["scene:1"],
            innerMonologue: "I should revise what I thought earlier.",
            channel: .selfCorrection,
            continuity: .revise,
            confidence: 0.8,
            salience: 0.8,
            novelty: 0.8
        )
        _ = await workspace.ingest(MentalEvidenceEvent(
            id: "scene:2",
            kind: .sceneTransition,
            summary: "The scene changed again.",
            confidence: 1,
            novelty: 1
        ))

        do {
            _ = try await workspace.applyThoughtUpdate(staleUpdate)
            XCTFail("stale update should be rejected")
        } catch let error as PersistentMentalWorkspaceError {
            guard case .staleRevision = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAdaptivePeriodicProbabilityRisesWithElapsedTimeAndCuriosity() async {
        let start = Date(timeIntervalSince1970: 500)
        let quiet = PersistentMentalWorkspace(snapshot: MentalWorkspaceSnapshot(updatedAt: start))
        let quietEarly = await quiet.periodicThoughtProbability(at: start.addingTimeInterval(5))
        let quietLate = await quiet.periodicThoughtProbability(at: start.addingTimeInterval(150))
        XCTAssertGreaterThan(quietLate, quietEarly)

        let curious = PersistentMentalWorkspace(snapshot: MentalWorkspaceSnapshot(
            updatedAt: start,
            drives: MentalDriveState(curiosity: 0.9)
        ))
        let curiousProbability = await curious.periodicThoughtProbability(at: start.addingTimeInterval(30))
        let quietProbability = await quiet.periodicThoughtProbability(at: start.addingTimeInterval(30))
        XCTAssertGreaterThan(curiousProbability, quietProbability)
    }

    func testSelectiveCheckpointRestoresDurableThoughtButClearsTransientAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-mental-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = CognitiveMemoryEncryptionKey.generate()
        let store = try MentalWorkspaceCheckpointStore(directoryURL: directory, encryptionKey: key)
        let personID = UUID()
        let hypothesis = MentalHypothesis(
            id: UUID(),
            kind: .curiosity,
            subjectEntityID: personID,
            content: "I still want to understand what they are building.",
            confidence: 0.8,
            salience: 0.7,
            createdAt: Date(timeIntervalSince1970: 600),
            lastSupportedAt: Date(timeIntervalSince1970: 600),
            evidenceIDs: ["conversation:1"],
            status: .active
        )
        let intention = MentalIntention(
            domain: "social",
            objective: "Ask about the project when appropriate.",
            attentionTargetLabel: "desk_project",
            pressure: 0.9,
            evidenceIDs: ["conversation:1"],
            createdAt: Date(timeIntervalSince1970: 600)
        )
        let snapshot = MentalWorkspaceSnapshot(
            revision: 7,
            updatedAt: Date(timeIntervalSince1970: 610),
            context: MentalContextState(
                presentEntityIDs: [personID],
                eyeContactActive: true,
                participantSpeaking: true,
                conversationActive: true,
                socialAvailability: 0.95,
                relationshipUncertainty: 0.2,
                updatedAt: Date(timeIntervalSince1970: 610),
                evidenceIDs: ["gaze:1"]
            ),
            hypotheses: [hypothesis],
            drives: MentalDriveState(
                curiosity: 0.8,
                concern: 0.2,
                boredom: 0.1,
                socialInterest: 0.9,
                interruptionPressure: 0.9
            ),
            intentions: [intention],
            recentNovelty: 0.9,
            processedEvidenceIDs: ["gaze:1"]
        )
        try await store.save(snapshot)

        let checkpointURL = directory.appendingPathComponent(MentalWorkspaceCheckpointStore.checkpointFilename)
        let raw = try String(decoding: Data(contentsOf: checkpointURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("understand what they are building"))

        let loaded = try await store.loadSelective(at: Date(timeIntervalSince1970: 700))
        let restored = try XCTUnwrap(loaded)
        XCTAssertTrue(restored.restoredStale)
        XCTAssertEqual(restored.hypotheses, [hypothesis])
        XCTAssertTrue(restored.context.presentEntityIDs.isEmpty)
        XCTAssertFalse(restored.context.eyeContactActive)
        XCTAssertFalse(restored.context.participantSpeaking)
        XCTAssertFalse(restored.context.conversationActive)
        XCTAssertEqual(restored.context.socialAvailability, 0)
        XCTAssertEqual(restored.context.relationshipUncertainty, 0.2)
        XCTAssertEqual(restored.drives.interruptionPressure, 0)
        XCTAssertEqual(restored.intentions.first?.pressure, 0)
        XCTAssertEqual(restored.intentions.first?.attentionTargetLabel, "desk_project")
        XCTAssertTrue(restored.processedEvidenceIDs.isEmpty)
    }
}
