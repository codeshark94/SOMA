import Foundation
import XCTest
@testable import SOMACore

final class ConsciousnessStreamTests: XCTestCase {
    func testSharedQueuePrioritizesExecutivesAndCoalescesThoughtWork() throws {
        var queue = L1ConsciousnessWorkQueue()
        queue.enqueue(makeThoughtRequest(wakeKind: .periodic, revision: 4))
        queue.enqueue(makeThoughtRequest(wakeKind: .periodic, revision: 5))
        queue.enqueue(makeThoughtRequest(wakeKind: .event, revision: 6, evidenceID: "scene:6"))
        queue.enqueue(makeThoughtRequest(wakeKind: .event, revision: 7, evidenceID: "scene:7"))

        let firstExecutive = makeExecutiveRequest(revision: 7)
        let secondExecutive = makeExecutiveRequest(revision: 7)
        queue.enqueue(firstExecutive)
        queue.enqueue(firstExecutive)
        queue.enqueue(secondExecutive)

        XCTAssertEqual(queue.executiveCount, 2)
        XCTAssertTrue(queue.hasEventThought)
        XCTAssertFalse(queue.hasPeriodicThought)

        guard case let .executive(first)? = queue.dequeue() else {
            return XCTFail("first work item should be executive")
        }
        guard case let .executive(second)? = queue.dequeue() else {
            return XCTFail("second work item should be executive")
        }
        guard case let .thought(thought)? = queue.dequeue() else {
            return XCTFail("event thought should follow executives")
        }
        XCTAssertEqual(first.cycleID, firstExecutive.cycleID)
        XCTAssertEqual(second.cycleID, secondExecutive.cycleID)
        XCTAssertEqual(thought.workspace.revision, 7)
        XCTAssertEqual(thought.wakeKind, .event)
        XCTAssertEqual(thought.evidence.map(\.id), ["scene:6", "scene:7"])
        XCTAssertTrue(thought.beliefSummary.contains("Evidence scene:6"))
        XCTAssertTrue(thought.beliefSummary.contains("Evidence scene:7"))
        XCTAssertTrue(queue.isEmpty)
    }

    func testPendingEventCoalescingIsIdempotentAndUsesNewestAuthority() {
        var queue = L1ConsciousnessWorkQueue()
        queue.enqueue(makeThoughtRequest(wakeKind: .event, revision: 5, evidenceID: "scene:5"))
        queue.enqueue(makeThoughtRequest(wakeKind: .event, revision: 6, evidenceID: "scene:5"))
        queue.enqueue(makeThoughtRequest(wakeKind: .event, revision: 7, evidenceID: "scene:7"))

        guard case let .thought(request)? = queue.dequeue() else {
            return XCTFail("coalesced event thought should be available")
        }
        XCTAssertEqual(request.workspace.revision, 7)
        XCTAssertEqual(request.evidence.map(\.id), ["scene:5", "scene:7"])
        XCTAssertEqual(request.observedAt, Date(timeIntervalSince1970: 27))
    }

    func testPendingEventCoalescingPreservesActiveCaptureVisual() {
        let capture = L1VisualResource(
            resourceID: "embodiment_capture:inspection-1",
            projection: .currentView,
            localPath: "/private/tmp/inspection-1.jpg",
            expiresAt: Date(timeIntervalSince1970: 120)
        )
        let current = L1VisualResource(
            resourceID: "current_frame",
            projection: .currentView,
            localPath: "/private/tmp/current.jpg",
            expiresAt: Date(timeIntervalSince1970: 121)
        )
        var queue = L1ConsciousnessWorkQueue()
        queue.enqueue(makeThoughtRequest(
            wakeKind: .event,
            revision: 6,
            evidenceID: "active-vision:1",
            visuals: [capture]
        ))
        queue.enqueue(makeThoughtRequest(
            wakeKind: .event,
            revision: 7,
            evidenceID: "scene:7",
            visuals: [current]
        ))

        guard case let .thought(request)? = queue.dequeue() else {
            return XCTFail("coalesced event thought should be available")
        }
        XCTAssertEqual(request.visuals.map(\.resourceID), [capture.resourceID, current.resourceID])
    }

    func testL1ARejectsAnyBehaviorOrSocialActionField() throws {
        let request = makeThoughtRequest()
        let data = Data("""
        {
          "expected_revision": 4,
          "evidence_ids": ["scene:1"],
          "inner_monologue": "The situation is stable, so I can let the earlier hypothesis weaken.",
          "channel": "self_correction",
          "continuity": "revise",
          "parent_thought_id": null,
          "confidence": 0.8,
          "salience": 0.6,
          "novelty": 0.4,
          "hypothesis_mutations": [],
          "drive_signal": {"curiosity":0,"concern":-0.1,"boredom":0.1,"social_interest":0,"interruption_pressure":0},
          "intention": null,
          "requested_visual_resource_ids": [],
          "memory_proposals": [],
          "action": "keep_observing"
        }
        """.utf8)

        XCTAssertThrowsError(try L1ThoughtResponseDecoder.decode(data, for: request)) { error in
            XCTAssertEqual(error as? ConsciousnessResponseError, .forbiddenThoughtField("action"))
        }
    }

    func testL1AProducesOnlyEvidenceGroundedThoughtAndStateMutations() throws {
        let hypothesisID = UUID()
        let hypothesis = MentalHypothesis(
            id: hypothesisID,
            kind: .situational,
            content: "The person may be focused on a device.",
            confidence: 0.6,
            salience: 0.5,
            createdAt: Date(timeIntervalSince1970: 10),
            lastSupportedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["scene:1"],
            status: .active
        )
        let request = makeThoughtRequest(hypotheses: [hypothesis])
        let json = """
        {
          "expected_revision": 4,
          "evidence_ids": ["scene:1"],
          "inner_monologue": "Nothing new supports my earlier interpretation; I should hold it more lightly.",
          "channel": "self_correction",
          "continuity": "revise",
          "parent_thought_id": null,
          "confidence": 0.85,
          "salience": 0.7,
          "novelty": 0.5,
          "hypothesis_mutations": [{
            "operation":"contradict",
            "hypothesis_id":"\(hypothesisID.uuidString)",
            "seed":null,
            "strength":0.45,
            "evidence_ids":["scene:1"]
          }],
          "drive_signal": {"curiosity":0,"concern":-0.2,"boredom":0.1,"social_interest":0,"interruption_pressure":0},
          "intention": null,
          "requested_visual_resource_ids": [],
          "memory_proposals": []
        }
        """

        let update = try L1ThoughtResponseDecoder.decode(Data(json.utf8), for: request)
        XCTAssertEqual(update.channel, .selfCorrection)
        XCTAssertEqual(update.hypothesisMutations.first?.hypothesisID, hypothesisID)
        XCTAssertNil(update.intention)
    }

    func testL1ARejectsInventedEvidence() {
        let request = makeThoughtRequest()
        let data = Data("""
        {
          "expected_revision": 4,
          "evidence_ids": ["invented"],
          "inner_monologue": "I invented evidence.",
          "channel": "perceptual",
          "continuity": "revise",
          "parent_thought_id": null,
          "confidence": 0.8,
          "salience": 0.5,
          "novelty": 0.5,
          "hypothesis_mutations": [],
          "drive_signal": {"curiosity":0,"concern":0,"boredom":0,"social_interest":0,"interruption_pressure":0},
          "intention": null,
          "requested_visual_resource_ids": [],
          "memory_proposals": []
        }
        """.utf8)
        XCTAssertThrowsError(try L1ThoughtResponseDecoder.decode(data, for: request))
    }

    func testSemanticAuthorityFailureRebasesInsteadOfRetryingIdenticalRequest() {
        let unavailable = ConsciousnessResponseError.validationFailed([
            "thought references unavailable evidence",
        ])
        XCTAssertFalse(unavailable.permitsIdenticalRequestRetry)
        XCTAssertTrue(unavailable.requiresAuthorityRebase)

        let unknownField = ConsciousnessResponseError.validationFailed([
            "unknown thought field: invented",
        ])
        XCTAssertFalse(unknownField.permitsIdenticalRequestRetry)
        XCTAssertFalse(unknownField.requiresAuthorityRebase)

        XCTAssertTrue(ConsciousnessResponseError.malformedJSON.permitsIdenticalRequestRetry)
        XCTAssertFalse(ConsciousnessResponseError.malformedJSON.requiresAuthorityRebase)
        XCTAssertFalse(
            ConsciousnessResponseError.forbiddenThoughtField("action")
                .permitsIdenticalRequestRetry
        )
    }

    func testThoughtAuthorityRebaseIsBoundedAndSurvivesVisualContinuation() {
        let original = makeThoughtRequest()
        let rebased = L1ThoughtRequest(
            observedAt: original.observedAt,
            wakeKind: original.wakeKind,
            workspace: original.workspace,
            evidence: original.evidence,
            beliefSummary: original.beliefSummary,
            authorityRebaseAttempt: 1
        )
        let continued = rebased.continuing(with: [
            L1VisualResource(
                resourceID: "current_frame",
                projection: .currentView,
                localPath: "/private/tmp/current.jpg",
                expiresAt: Date(timeIntervalSince1970: 120)
            ),
        ])

        XCTAssertEqual(rebased.authorityRebaseAttempt, 1)
        XCTAssertEqual(continued.authorityRebaseAttempt, 1)
    }

    func testL1BIsBoundToOneRevisionIntentionAndAllowedAction() throws {
        let intention = MentalIntention(
            id: UUID(),
            domain: "attention",
            objective: "Resume exploration after an unproductive fixation.",
            pressure: 0.8,
            evidenceIDs: ["behavior:1"]
        )
        let thought = ThoughtCandidate(
            channel: .selfCorrection,
            content: "This fixation is no longer informative.",
            confidence: 0.9,
            salience: 0.8,
            novelty: 0.7,
            continuity: .revise
        )
        let request = L1ExecutiveRequest(
            observedAt: Date(),
            workspaceRevision: 11,
            intention: intention,
            foregroundThought: thought,
            relatedHypotheses: [],
            context: .init(),
            availableActions: [.noAction, .resumeScanning],
            evidenceIDs: ["behavior:1"]
        )
        let json = """
        {
          "cycle_id":"\(request.cycleID.uuidString)",
          "expected_revision":11,
          "intention_episode_id":"\(intention.id.uuidString)",
          "action":"resume_scanning",
          "confidence":0.9,
          "rationale":"The foreground intention is grounded and current.",
          "opening":null,
          "motive_id":null
        }
        """
        let decision = try L1ExecutiveResponseDecoder.decode(Data(json.utf8), for: request)
        XCTAssertEqual(decision.action, .resumeScanning)
    }

    func testL1BRejectsAnActionOutsideCurrentAuthority() {
        let intention = MentalIntention(
            domain: "attention",
            objective: "Observe.",
            pressure: 0.7,
            evidenceIDs: ["behavior:1"]
        )
        let thought = ThoughtCandidate(
            channel: .perceptual,
            content: "A thought.",
            confidence: 0.8,
            salience: 0.7,
            novelty: 0.5,
            continuity: .continue
        )
        let request = L1ExecutiveRequest(
            observedAt: Date(),
            workspaceRevision: 3,
            intention: intention,
            foregroundThought: thought,
            relatedHypotheses: [],
            context: .init(),
            availableActions: [.noAction],
            evidenceIDs: ["behavior:1"]
        )
        let json = """
        {
          "cycle_id":"\(request.cycleID.uuidString)",
          "expected_revision":3,
          "intention_episode_id":"\(intention.id.uuidString)",
          "action":"resume_scanning",
          "confidence":0.9,
          "rationale":"Not authorized.",
          "opening":null,
          "motive_id":null
        }
        """
        XCTAssertThrowsError(try L1ExecutiveResponseDecoder.decode(Data(json.utf8), for: request))
    }

    func testL1BRejectsThoughtFieldsAndUngroundedSpokenOpening() {
        let request = makeExecutiveRequest(revision: 8)
        let thoughtFieldJSON = """
        {
          "cycle_id":"\(request.cycleID.uuidString)",
          "expected_revision":8,
          "intention_episode_id":"\(request.intention.id.uuidString)",
          "action":"no_action",
          "confidence":0.8,
          "rationale":"No action is warranted.",
          "opening":null,
          "motive_id":null,
          "inner_monologue":"This field is forbidden in L1b."
        }
        """
        XCTAssertThrowsError(
            try L1ExecutiveResponseDecoder.decode(Data(thoughtFieldJSON.utf8), for: request)
        )

        let personID = UUID()
        let socialRequest = L1ExecutiveRequest(
            cycleID: request.cycleID,
            observedAt: Date(),
            workspaceRevision: 8,
            intention: request.intention,
            foregroundThought: request.foregroundThought,
            relatedHypotheses: [],
            context: MentalContextState(presentEntityIDs: [personID], socialAvailability: 0.8),
            availableActions: [.noAction, .spokenOpening],
            socialOpportunity: L1SocialOpportunity(
                entityID: personID,
                observedAtNS: 1,
                recognitionConfidence: 0.9,
                availableActions: [.remainSilent, .spokenOpening]
            ),
            informationNeeds: [],
            evidenceIDs: ["behavior:1"]
        )
        let ungroundedOpeningJSON = """
        {
          "cycle_id":"\(socialRequest.cycleID.uuidString)",
          "expected_revision":8,
          "intention_episode_id":"\(socialRequest.intention.id.uuidString)",
          "action":"spoken_opening",
          "confidence":0.9,
          "rationale":"Speak now.",
          "opening":"Hello.",
          "motive_id":"\(UUID().uuidString)"
        }
        """
        XCTAssertThrowsError(
            try L1ExecutiveResponseDecoder.decode(Data(ungroundedOpeningJSON.utf8), for: socialRequest)
        )
    }

    private func makeThoughtRequest(
        hypotheses: [MentalHypothesis] = [],
        wakeKind: L1ThoughtWakeKind = .event,
        revision: UInt64 = 4,
        evidenceID: String = "scene:1",
        visuals: [L1VisualResource] = []
    ) -> L1ThoughtRequest {
        let evidence = MentalEvidenceEvent(
            id: evidenceID,
            observedAt: Date(timeIntervalSince1970: 20 + Double(revision)),
            kind: .sceneTransition,
            summary: "Evidence \(evidenceID) changed the scene.",
            confidence: 1,
            novelty: 0.8
        )
        return L1ThoughtRequest(
            observedAt: evidence.observedAt,
            wakeKind: wakeKind,
            workspace: MentalWorkspaceSnapshot(
                revision: revision,
                updatedAt: evidence.observedAt,
                hypotheses: hypotheses,
                processedEvidenceIDs: [evidence.id]
            ),
            evidence: [evidence],
            beliefSummary: evidence.summary,
            visuals: visuals
        )
    }

    private func makeExecutiveRequest(revision: UInt64) -> L1ExecutiveRequest {
        let intention = MentalIntention(
            domain: "attention",
            objective: "Reassess the current attention state.",
            pressure: 0.7,
            evidenceIDs: ["behavior:1"]
        )
        return L1ExecutiveRequest(
            observedAt: Date(),
            workspaceRevision: revision,
            intention: intention,
            foregroundThought: ThoughtCandidate(
                channel: .selfCorrection,
                content: "The current attention state may no longer be useful.",
                confidence: 0.8,
                salience: 0.7,
                novelty: 0.5,
                continuity: .revise
            ),
            relatedHypotheses: [],
            context: .init(),
            availableActions: [.noAction, .resumeScanning],
            evidenceIDs: ["behavior:1"]
        )
    }
}
