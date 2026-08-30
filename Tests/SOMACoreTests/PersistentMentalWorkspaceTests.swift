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

    func testDriveDecayIsIncrementalAndDoesNotCompoundFromOriginalTimestamp() async {
        let start = Date(timeIntervalSince1970: 550)
        let policy = MentalDynamicsPolicy(
            curiosityDriveHalfLifeSeconds: 10,
            concernDriveHalfLifeSeconds: 10,
            boredomDriveHalfLifeSeconds: 10,
            socialDriveHalfLifeSeconds: 10,
            interruptionDriveHalfLifeSeconds: 10
        )
        let workspace = PersistentMentalWorkspace(
            snapshot: MentalWorkspaceSnapshot(
                updatedAt: start,
                drives: MentalDriveState(
                    curiosity: 0.8,
                    concern: 0.8,
                    boredom: 0.8,
                    socialInterest: 0.8,
                    interruptionPressure: 0.8
                )
            ),
            policy: policy
        )

        let first = await workspace.snapshot(at: start.addingTimeInterval(10))
        let second = await workspace.snapshot(at: start.addingTimeInterval(20))

        XCTAssertEqual(first.drives.curiosity, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(second.drives.curiosity, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(second.drives.interruptionPressure, 0.2, accuracy: 0.000_001)
    }

    func testResolvingCuriosityHypothesisSatisfiesCuriosityDrive() async throws {
        let start = Date(timeIntervalSince1970: 580)
        let workspace = PersistentMentalWorkspace(snapshot: MentalWorkspaceSnapshot(updatedAt: start))
        let evidence = MentalEvidenceEvent(
            id: "curiosity:answerable",
            observedAt: start,
            kind: .memoryAssociation,
            summary: "A concrete question remains unresolved.",
            confidence: 1,
            novelty: 0.8,
            hypothesis: MentalHypothesisSeed(
                kind: .curiosity,
                content: "I want to know what this device is for.",
                confidence: 0.9,
                salience: 0.8
            ),
            driveSignal: MentalDriveSignal(curiosity: 0.9)
        )
        let ingested = await workspace.ingest(evidence)
        let hypothesisID = try XCTUnwrap(ingested.after.hypotheses.first?.id)
        let update = L1ThoughtUpdate(
            expectedRevision: ingested.after.revision,
            evidenceIDs: [evidence.id],
            innerMonologue: "The answer resolves that specific question, so its pressure can subside.",
            channel: .selfCorrection,
            continuity: .retire,
            confidence: 1,
            salience: 0.6,
            novelty: 0.5,
            hypothesisMutations: [MentalHypothesisMutation(
                operation: .resolve,
                hypothesisID: hypothesisID,
                strength: 1,
                evidenceIDs: [evidence.id]
            )]
        )

        let resolved = try await workspace.applyThoughtUpdate(update, at: start)
        XCTAssertEqual(resolved.after.hypotheses.first?.status, .resolved)
        XCTAssertLessThan(resolved.after.drives.curiosity, 0.2)
        XCTAssertTrue(resolved.delta.changedFields.contains("drive_satisfied:curiosity"))
    }

    func testRecentForegroundPaysContinuousRepetitionCost() async throws {
        let start = Date(timeIntervalSince1970: 590)
        let workspace = PersistentMentalWorkspace(snapshot: MentalWorkspaceSnapshot(updatedAt: start))
        let event = MentalEvidenceEvent(
            id: "social:stable",
            observedAt: start,
            kind: .directSocialBid,
            summary: "A stable social opportunity exists.",
            confidence: 1,
            novelty: 0.8
        )
        let ingested = await workspace.ingest(event)
        let first = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: ingested.after.revision,
            evidenceIDs: [event.id],
            innerMonologue: "The person is socially available.",
            channel: .social,
            continuity: .continue,
            confidence: 0.9,
            salience: 0.8,
            novelty: 0.8
        ), at: start, draw: 0)
        XCTAssertEqual(first.after.foregroundThought?.channel, .social)

        let second = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: first.after.revision,
            evidenceIDs: [event.id],
            innerMonologue: "The quiet interval also gives me room to reconsider an unresolved question.",
            channel: .curiosity,
            continuity: .associate,
            confidence: 0.9,
            salience: 0.8,
            novelty: 0.8
        ), at: start.addingTimeInterval(1), draw: 0.5)
        XCTAssertEqual(second.after.foregroundThought?.channel, .curiosity)
    }

    func testRepeatedThoughtCannotRefreshItsOwnNoveltyToOne() async throws {
        let start = Date(timeIntervalSince1970: 595)
        let workspace = PersistentMentalWorkspace(snapshot: MentalWorkspaceSnapshot(updatedAt: start))
        let event = MentalEvidenceEvent(
            id: "scene:stable",
            observedAt: start,
            kind: .ordinaryObservation,
            summary: "The scene remains stable.",
            confidence: 1,
            novelty: 0.6
        )
        let ingested = await workspace.ingest(event)
        let text = "The same stable scene does not require a new interpretation."
        let first = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: ingested.after.revision,
            evidenceIDs: [event.id],
            innerMonologue: text,
            channel: .idle,
            continuity: .idle,
            confidence: 0.9,
            salience: 0.7,
            novelty: 0.5
        ), at: start, draw: 0)
        let repeated = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: first.after.revision,
            evidenceIDs: [event.id],
            innerMonologue: text,
            channel: .idle,
            continuity: .continue,
            confidence: 0.9,
            salience: 1,
            novelty: 1
        ), at: start.addingTimeInterval(1), draw: 0)

        XCTAssertEqual(repeated.after.thoughtCandidates.count, 1)
        XCTAssertLessThanOrEqual(repeated.after.thoughtCandidates[0].novelty, 0.20)
        XCTAssertLessThan(repeated.after.thoughtCandidates[0].salience, 0.9)
    }

    func testDispatchingSocialIntentionDoesNotPretendItsGoalIsComplete() async {
        let intention = MentalIntention(
            domain: "social",
            objective: "Make one bounded social invitation.",
            pressure: 1,
            evidenceIDs: ["social:episode"]
        )
        let workspace = PersistentMentalWorkspace(snapshot: MentalWorkspaceSnapshot(
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 599),
            drives: MentalDriveState(
                curiosity: 0.8,
                socialInterest: 0.9,
                interruptionPressure: 1
            ),
            intentions: [intention],
            processedEvidenceIDs: ["social:episode"]
        ))

        let marked = await workspace.markIntentionExecuted(
            intention.id,
            using: ["social:episode"],
            actionFingerprint: "spoken_opening"
        )
        XCTAssertTrue(marked)
        let snapshot = await workspace.currentSnapshot()
        XCTAssertEqual(snapshot.drives.interruptionPressure, 1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.drives.socialInterest, 0.9, accuracy: 0.000_001)
        XCTAssertNotNil(snapshot.intentions.first?.executedAt)
        XCTAssertNil(snapshot.intentions.first?.completedAt)
        XCTAssertFalse(snapshot.intentions[0].canDispatch(
            using: ["social:episode"],
            actionFingerprint: "spoken_opening"
        ))
        XCTAssertFalse(snapshot.intentions[0].canDispatch(
            using: ["action:outcome"],
            actionFingerprint: "spoken_opening"
        ))
        XCTAssertTrue(snapshot.intentions[0].canDispatch(
            using: ["action:outcome"],
            actionFingerprint: "nonverbal_invitation"
        ))
    }

    func testPassiveDecayDoesNotInvalidateSemanticRevision() async {
        let start = Date(timeIntervalSince1970: 605)
        let hypothesis = MentalHypothesis(
            id: UUID(),
            kind: .perceptual,
            content: "A weak visual interpretation remains unresolved.",
            confidence: 0.8,
            salience: 0.7,
            createdAt: start,
            lastSupportedAt: start,
            evidenceIDs: ["vision:1"],
            status: .active
        )
        let workspace = PersistentMentalWorkspace(
            snapshot: MentalWorkspaceSnapshot(
                revision: 9,
                updatedAt: start,
                hypotheses: [hypothesis]
            ),
            policy: MentalDynamicsPolicy(perceptualHalfLifeSeconds: 10)
        )

        let decayed = await workspace.snapshot(at: start.addingTimeInterval(10))

        XCTAssertEqual(decayed.revision, 9)
        XCTAssertLessThan(decayed.hypotheses[0].confidence, hypothesis.confidence)
    }

    func testHypothesisLifecycleTransitionAdvancesRevisionOnlyAtCategoryBoundary() async {
        let start = Date(timeIntervalSince1970: 612)
        let workspace = PersistentMentalWorkspace(
            snapshot: MentalWorkspaceSnapshot(
                revision: 4,
                updatedAt: start,
                hypotheses: [MentalHypothesis(
                    id: UUID(),
                    kind: .perceptual,
                    content: "A transient interpretation is awaiting support.",
                    confidence: 0.8,
                    salience: 0.7,
                    createdAt: start,
                    lastSupportedAt: start,
                    evidenceIDs: ["vision:transient"],
                    status: .active
                )]
            ),
            policy: MentalDynamicsPolicy(
                perceptualHalfLifeSeconds: 10,
                dormantConfidence: 0.6,
                abandonedConfidence: 0.2
            )
        )

        let dormant = await workspace.snapshot(at: start.addingTimeInterval(5))
        XCTAssertEqual(dormant.hypotheses[0].status, .dormant)
        XCTAssertEqual(dormant.revision, 5)

        let stillDormant = await workspace.snapshot(at: start.addingTimeInterval(6))
        XCTAssertEqual(stillDormant.hypotheses[0].status, .dormant)
        XCTAssertEqual(stillDormant.revision, 5)

        let abandoned = await workspace.ingest(MentalEvidenceEvent(
            id: "time:ordinary",
            observedAt: start.addingTimeInterval(22),
            kind: .ordinaryObservation,
            summary: "No supporting evidence appeared.",
            confidence: 1,
            novelty: 0
        ))
        XCTAssertEqual(abandoned.after.hypotheses[0].status, .abandoned)
        XCTAssertEqual(abandoned.after.revision, 6)
        XCTAssertTrue(abandoned.delta.meaningfulTransition)
        XCTAssertTrue(abandoned.delta.changedFields.contains("hypothesis_lifecycle_decay"))
    }

    func testThoughtEpisodeContinuesAcrossRevisionsAndRetiresWithItsGoal() async throws {
        let start = Date(timeIntervalSince1970: 620)
        let workspace = PersistentMentalWorkspace()
        let ingested = await workspace.ingest(MentalEvidenceEvent(
            id: "object:presented",
            observedAt: start,
            kind: .objectPresentation,
            summary: "A person presented an object for closer inspection.",
            confidence: 1,
            novelty: 0.9
        ))
        let goalID = UUID()
        let first = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: ingested.after.revision,
            evidenceIDs: ["object:presented"],
            innerMonologue: "I need a closer observation before deciding what this object is.",
            channel: .curiosity,
            continuity: .associate,
            confidence: 0.9,
            salience: 0.9,
            novelty: 0.8,
            intention: MentalIntention(
                id: goalID,
                domain: "inspection",
                objective: "Acquire a grounded close view of the presented object.",
                completionCondition: "A current close view is acquired or the object is no longer available.",
                pressure: 0.8,
                evidenceIDs: ["object:presented"],
                createdAt: start
            )
        ), at: start, draw: 0)
        let firstThought = try XCTUnwrap(first.after.foregroundThought)
        let firstEpisode = try XCTUnwrap(first.after.thoughtEpisodes.first)
        XCTAssertEqual(firstThought.episodeID, firstEpisode.id)
        XCTAssertEqual(firstEpisode.goalEpisodeID, goalID)

        let revised = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: first.after.revision,
            evidenceIDs: ["object:presented"],
            innerMonologue: "The inspection goal remains, but I should use the narrowest current-frame observation first.",
            channel: .curiosity,
            continuity: .revise,
            parentThoughtID: firstThought.id,
            confidence: 0.9,
            salience: 0.8,
            novelty: 0.4
        ), at: start.addingTimeInterval(1), draw: 0)
        XCTAssertEqual(revised.after.thoughtEpisodes.count, 1)
        XCTAssertEqual(revised.after.thoughtEpisodes[0].id, firstEpisode.id)

        let marked = await workspace.markIntentionExecuted(
            goalID,
            using: ["object:presented"],
            actionFingerprint: "seek_people",
            at: start.addingTimeInterval(2)
        )
        XCTAssertTrue(marked)
        let dispatched = await workspace.currentSnapshot()
        XCTAssertEqual(dispatched.thoughtEpisodes[0].status, .active)
        XCTAssertNil(dispatched.intentions.first?.completedAt)

        do {
            _ = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
                expectedRevision: dispatched.revision,
                evidenceIDs: ["object:presented"],
                innerMonologue: "The request was dispatched, but I still lack completion evidence.",
                channel: .selfCorrection,
                continuity: .retire,
                parentThoughtID: revised.after.foregroundThought?.id,
                confidence: 0.8,
                salience: 0.4,
                novelty: 0.2,
                intentionResolution: MentalIntentionResolution(
                    intentionID: goalID,
                    outcome: .satisfied,
                    evidenceIDs: ["object:presented"],
                    explanation: "The original presentation does not prove the later capture completed."
                )
            ), at: start.addingTimeInterval(2.5), draw: 0)
            XCTFail("pre-dispatch evidence completed the goal")
        } catch PersistentMentalWorkspaceError.invalidThought {
        }

        let completionEvidence = await workspace.ingest(MentalEvidenceEvent(
            id: "capture:ready",
            observedAt: start.addingTimeInterval(3),
            kind: .cognitiveActionOutcome,
            summary: "A current close view was acquired.",
            confidence: 1,
            novelty: 0.7
        ))

        let retired = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: completionEvidence.after.revision,
            evidenceIDs: ["capture:ready"],
            innerMonologue: "The requested view is now grounded, so this inspection goal is complete.",
            channel: .selfCorrection,
            continuity: .retire,
            parentThoughtID: revised.after.foregroundThought?.id,
            confidence: 0.95,
            salience: 0.4,
            novelty: 0.3,
            intentionResolution: MentalIntentionResolution(
                intentionID: goalID,
                outcome: .satisfied,
                evidenceIDs: ["capture:ready"],
                explanation: "The current close view satisfies the observable completion condition."
            )
        ), at: start.addingTimeInterval(4), draw: 0)
        let completed = retired.after
        XCTAssertEqual(completed.thoughtEpisodes[0].status, .retired)
        XCTAssertNotNil(completed.intentions.first?.completedAt)
    }

    func testEquivalentActiveVisualIntentionsCoalesceAcrossFreshModelUUIDs() async throws {
        let start = Date(timeIntervalSince1970: 625)
        let workspace = PersistentMentalWorkspace()
        let firstEvidence = await workspace.ingest(MentalEvidenceEvent(
            id: "object:book:presented",
            observedAt: start,
            kind: .objectPresentation,
            summary: "A book is currently available for inspection.",
            confidence: 1,
            novelty: 0.9
        ))
        let canonicalID = UUID()
        let first = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: firstEvidence.after.revision,
            evidenceIDs: ["object:book:presented"],
            innerMonologue: "I need one current view to resolve what is on the book cover.",
            channel: .curiosity,
            continuity: .associate,
            confidence: 0.9,
            salience: 0.9,
            novelty: 0.8,
            intention: MentalIntention(
                id: canonicalID,
                domain: "visual inspection",
                objective: "Read the visible book cover.",
                completionCondition: "A settled current image answers the cover question.",
                attentionTargetLabel: "Book",
                pressure: 0.8,
                evidenceIDs: ["object:book:presented"],
                createdAt: start
            )
        ), at: start, draw: 0)
        let marked = await workspace.markIntentionExecuted(
            canonicalID,
            using: ["object:book:presented"],
            actionFingerprint: "inspect_attention_target",
            at: start.addingTimeInterval(1)
        )
        XCTAssertTrue(marked)
        let followupEvidence = await workspace.ingest(MentalEvidenceEvent(
            id: "object:book:stable",
            observedAt: start.addingTimeInterval(2),
            kind: .ordinaryObservation,
            summary: "The same book remains available.",
            confidence: 1,
            novelty: 0.2
        ))
        let freshModelID = UUID()
        let repeated = try await workspace.applyThoughtUpdate(L1ThoughtUpdate(
            expectedRevision: followupEvidence.after.revision,
            evidenceIDs: ["object:book:stable"],
            innerMonologue: "The same unresolved cover question remains; it is not a new inspection goal.",
            channel: .curiosity,
            continuity: .revise,
            parentThoughtID: first.after.foregroundThought?.id,
            confidence: 0.8,
            salience: 0.7,
            novelty: 0.2,
            intention: MentalIntention(
                id: freshModelID,
                domain: "perceptual inquiry",
                objective: "Inspect the book again.",
                completionCondition: "A current view resolves the uncertainty.",
                attentionTargetLabel: " book ",
                pressure: 0.7,
                evidenceIDs: ["object:book:stable"],
                createdAt: start.addingTimeInterval(2)
            )
        ), at: start.addingTimeInterval(2), draw: 0)

        let active = repeated.after.intentions.filter { $0.completedAt == nil }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, canonicalID)
        XCTAssertEqual(active.first?.lastDispatchedActionFingerprint, "inspect_attention_target")
        XCTAssertTrue(repeated.delta.changedFields.contains("intention_coalesced:\(canonicalID.uuidString.lowercased())"))
        XCTAssertEqual(repeated.after.thoughtEpisodes.last?.goalEpisodeID, canonicalID)
        XCTAssertFalse(active[0].canDispatch(
            using: ["object:book:stable"],
            actionFingerprint: "inspect_attention_target"
        ))
    }

    func testEquivalentCognitiveActionOutcomeIsIdempotentWithinOneGoal() async {
        let goalID = UUID()
        let firstEpisode = CognitiveActionEpisode(
            goalEpisodeID: goalID,
            sourceLayer: .l2,
            toolName: "get_person_context",
            effect: .epistemic,
            purpose: "Ground a relationship-aware follow-up.",
            expectedInformationGain: 0.7,
            evidenceIDs: ["turn:1"],
            status: .succeeded,
            resultFingerprint: "abc123",
            requestFingerprint: "semantic-request",
            resultSummary: "The participant context was refreshed."
        )
        let repeatedEpisode = CognitiveActionEpisode(
            goalEpisodeID: goalID,
            sourceLayer: .l2,
            toolName: "get_person_context",
            effect: .epistemic,
            purpose: "Use canonical context before the next reply.",
            expectedInformationGain: 0.7,
            evidenceIDs: ["turn:1"],
            status: .succeeded,
            resultFingerprint: "different-volatile-result",
            requestFingerprint: "semantic-request",
            resultSummary: "The participant context was refreshed."
        )
        let workspace = PersistentMentalWorkspace()
        let first = await workspace.ingest(MentalEvidenceEvent(
            id: "cognitive:\(firstEpisode.id)",
            kind: .cognitiveActionOutcome,
            summary: firstEpisode.resultSummary,
            confidence: 1,
            novelty: 0.7,
            cognitiveAction: firstEpisode
        ))
        let repeated = await workspace.ingest(MentalEvidenceEvent(
            id: "cognitive:\(repeatedEpisode.id)",
            kind: .cognitiveActionOutcome,
            summary: repeatedEpisode.resultSummary,
            confidence: 1,
            novelty: 0.7,
            cognitiveAction: repeatedEpisode
        ))

        XCTAssertEqual(first.after.cognitiveActions.count, 1)
        XCTAssertEqual(repeated.after.cognitiveActions.count, 1)
        XCTAssertFalse(repeated.changed)
        XCTAssertEqual(repeated.after.revision, first.after.revision)
        let sameRequest = await workspace.containsCognitiveAction(CognitiveActionQuery(
            goalEpisodeID: goalID,
            toolName: "get_person_context",
            requestFingerprint: "semantic-request",
            evidenceIDs: ["turn:1"]
        ))
        let newEvidence = await workspace.containsCognitiveAction(CognitiveActionQuery(
            goalEpisodeID: goalID,
            toolName: "get_person_context",
            requestFingerprint: "semantic-request",
            evidenceIDs: ["turn:2"]
        ))
        XCTAssertTrue(sameRequest)
        XCTAssertFalse(newEvidence)
    }

    func testCognitiveActionReservationIsAtomicUntilItsOutcomeIsRecorded() async {
        let goalID = UUID()
        let query = CognitiveActionQuery(
            goalEpisodeID: goalID,
            toolName: "capture_view",
            requestFingerprint: "capture-request",
            evidenceIDs: ["turn:1"]
        )
        let workspace = PersistentMentalWorkspace()
        let firstReservation = await workspace.reserveCognitiveAction(
            query,
            at: Date(timeIntervalSince1970: 700)
        )
        let repeatedReservation = await workspace.reserveCognitiveAction(
            query,
            at: Date(timeIntervalSince1970: 701)
        )
        XCTAssertFalse(firstReservation)
        XCTAssertTrue(repeatedReservation)

        let episode = CognitiveActionEpisode(
            goalEpisodeID: goalID,
            sourceLayer: .l2,
            toolName: "capture_view",
            effect: .reversibleEmbodiment,
            purpose: "Ground the current visual reference.",
            expectedInformationGain: 0.8,
            evidenceIDs: ["turn:1"],
            status: .succeeded,
            resultFingerprint: "result",
            requestFingerprint: "capture-request",
            resultSummary: "Current visual evidence was acquired.",
            completedAt: Date(timeIntervalSince1970: 702)
        )
        _ = await workspace.ingest(MentalEvidenceEvent(
            id: "cognitive:\(episode.id.uuidString.lowercased())",
            observedAt: episode.completedAt,
            kind: .cognitiveActionOutcome,
            summary: episode.resultSummary,
            confidence: 1,
            novelty: 0.7,
            cognitiveAction: episode
        ))
        let completedReservation = await workspace.reserveCognitiveAction(
            query,
            at: Date(timeIntervalSince1970: 703)
        )
        XCTAssertTrue(completedReservation)
    }

    func testLegacyCheckpointWithoutEpisodeOrActionCollectionsStillDecodes() throws {
        let legacyIntentionID = UUID()
        let legacy = Data("""
        {
          "schemaVersion": 1,
          "revision": 7,
          "updatedAt": 600,
          "restoredStale": false,
          "hypotheses": [],
          "thoughtCandidates": [],
          "intentions": [{
            "id": "\(legacyIntentionID.uuidString)",
            "domain": "social",
            "objective": "Continue a previously unresolved social goal.",
            "pressure": 0.5,
            "evidenceIDs": ["legacy:evidence"],
            "createdAt": 600
          }],
          "recentNovelty": 0.4,
          "processedEvidenceIDs": ["legacy:evidence"]
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let snapshot = try decoder.decode(MentalWorkspaceSnapshot.self, from: legacy)

        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.recentNovelty, 0.4)
        XCTAssertEqual(snapshot.processedEvidenceIDs, ["legacy:evidence"])
        XCTAssertTrue(snapshot.thoughtEpisodes.isEmpty)
        XCTAssertTrue(snapshot.cognitiveActions.isEmpty)
        XCTAssertEqual(snapshot.intentions.first?.id, legacyIntentionID)
        XCTAssertNil(snapshot.intentions.first?.completedAt)
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
