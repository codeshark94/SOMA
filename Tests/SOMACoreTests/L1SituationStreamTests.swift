#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class L1SituationStreamTests: XCTestCase {
    func testContactEpisodeRecordsObservedResponseAndClosureWithoutInventingIntent() {
        var episode = L1ConversationContactEpisode()
        XCTAssertFalse(episode.observeFinalizedTurn(role: .assistant))
        XCTAssertFalse(episode.participantResponded)
        XCTAssertTrue(episode.observeFinalizedTurn(role: .user))
        XCTAssertFalse(episode.observeFinalizedTurn(role: .user))
        XCTAssertEqual(episode.closureKind(interrupted: false), .conversationEnded)
        XCTAssertEqual(episode.closureKind(interrupted: true), .conversationInterrupted)

        XCTAssertEqual(
            L1ConversationContactEpisode().closureKind(interrupted: false),
            .conversationEndedWithoutParticipantTurn
        )
    }

    func testGemmaOwnsBothL1WorkloadsWithoutChangingTheirContract() throws {
        let configuration = L1ModelConfiguration.gemma31
        XCTAssertEqual(configuration.model, "gemma4:31b-cloud")
        XCTAssertEqual(configuration.deadlineMilliseconds(for: .situation), 20_000)
        XCTAssertEqual(configuration.deadlineMilliseconds(for: .memoryConsolidation), 60_000)

        let request = fixtureRequest()
        XCTAssertTrue(request.visuals.isEmpty)
        let frame = L1SituationFrame(
            cycleID: request.cycleID,
            summary: "A familiar person is present; no interruption is currently warranted.",
            uncertainty: 0.2,
            evidenceIDs: request.evidenceIDs
        )
        XCTAssertNoThrow(try L1SituationFrameValidator().validate(frame, for: request))
    }

    func testDailyWorldMemoryIsBoundedAndRequiresHTTPSProvenance() {
        let memory = L1DailyWorldMemory(
            localDay: "2026-08-16",
            collectedAt: Date(timeIntervalSince1970: 10),
            topics: [
                L1DailyWorldTopic(
                    title: "A current science development",
                    summary: "A concise sourced factual summary.",
                    sourceURL: "https://example.com/news",
                    tags: ["science", "research"]
                ),
                L1DailyWorldTopic(
                    title: "Unsourced topic",
                    summary: "This must not enter the L1 packet.",
                    sourceURL: "http://example.com/news",
                    tags: []
                ),
            ]
        )
        XCTAssertEqual(memory.topics.count, 1)
        XCTAssertEqual(memory.topics.first?.tags, ["science", "research"])
    }

    func testContactHistoryIsBoundedAndNewestFirstForL1() {
        let first = Date(timeIntervalSince1970: 10)
        let latest = Date(timeIntervalSince1970: 20)
        let request = L1SituationRequest(
            observedAt: latest,
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            contactHistory: [
                L1SocialContactEvent(
                    kind: .nonverbalInvitation,
                    occurredAt: first,
                    purpose: "A brief acknowledgement."
                ),
                L1SocialContactEvent(
                    kind: .conversationOpened,
                    occurredAt: latest,
                    purpose: "A Live voice conversation became active."
                ),
            ]
        )
        XCTAssertEqual(request.contactHistory.map(\.kind), [.conversationOpened, .nonverbalInvitation])
        XCTAssertEqual(request.contactHistory.first?.purpose, "A Live voice conversation became active.")
    }

    func testRebasedSocialOpportunityPreservesModelEvidenceButRefreshesL0Authority() {
        let person = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 1_000,
            recognitionConfidence: 0.92,
            availableActions: [.remainSilent, .nonverbalInvitation]
        )
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            socialOpportunity: opportunity,
            contactPattern: .init(
                eyeContactActive: true,
                recentEpisodeCount: 3,
                latestEpisodeAgeSeconds: 0,
                activeDurationSeconds: 1.2
            )
        )

        let rebased = request.rebasingSocialOpportunity(at: 9_000_000_000)

        XCTAssertEqual(rebased.cycleID, request.cycleID)
        XCTAssertEqual(rebased.evidenceIDs, request.evidenceIDs)
        XCTAssertEqual(rebased.contactPattern, request.contactPattern)
        XCTAssertEqual(rebased.socialOpportunity?.id, opportunity.id)
        XCTAssertEqual(rebased.socialOpportunity?.observedAtNS, 9_000_000_000)
    }

    func testVisualFollowupMayOnlyRequestAnOfferedResourceOnce() throws {
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            visualResourceOffers: [
                L1VisualResourceOffer(
                    resourceID: "spherical_atlas_current",
                    projection: .sphericalAtlas,
                    description: "Current panorama.",
                    expiresAt: Date(timeIntervalSince1970: 60)
                ),
            ]
        )
        let requestVisual = L1SituationFrame(
            cycleID: request.cycleID,
            summary: "A panorama would clarify the scene.",
            uncertainty: 0.4,
            evidenceIDs: request.evidenceIDs,
            requestedVisualResourceIDs: ["spherical_atlas_current"]
        )
        XCTAssertNoThrow(try L1SituationFrameValidator().validate(requestVisual, for: request))

        let unavailable = L1SituationFrame(
            cycleID: request.cycleID,
            summary: "An unavailable view is needed.",
            uncertainty: 0.4,
            evidenceIDs: request.evidenceIDs,
            requestedVisualResourceIDs: ["invented"]
        )
        XCTAssertThrowsError(try L1SituationFrameValidator().validate(unavailable, for: request))

        let continued = request.continuing(with: [
            L1VisualResource(
                resourceID: "spherical_atlas_current",
                projection: .sphericalAtlas,
                localPath: "/private/tmp/panorama.jpg",
                expiresAt: Date(timeIntervalSince1970: 60)
            ),
        ])
        XCTAssertThrowsError(try L1SituationFrameValidator().validate(requestVisual, for: continued))
    }

    func testAttachedCurrentVisualResourceIsValidSituationEvidence() throws {
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["behavior:1"],
            beliefSummary: "The current behavior requires review.",
            visuals: [
                L1VisualResource(
                    resourceID: "current_frame",
                    projection: .currentView,
                    localPath: "/private/tmp/current-frame.jpg",
                    expiresAt: Date(timeIntervalSince1970: 60)
                ),
            ]
        )
        let frame = L1SituationFrame(
            cycleID: request.cycleID,
            summary: "The attached view grounds the current assessment.",
            uncertainty: 0.2,
            evidenceIDs: ["current_frame"]
        )
        XCTAssertNoThrow(try L1SituationFrameValidator().validate(frame, for: request))
    }

    func testModelOutputCannotInventMemoryEvidenceOrConversationTurns() {
        let request = fixtureRequest()
        let frame = L1SituationFrame(
            cycleID: request.cycleID,
            summary: "A preference was inferred.",
            uncertainty: 0.3,
            evidenceIDs: request.evidenceIDs,
            memoryProposals: [
                L1MemoryProposal(
                    kind: .personFact,
                    summary: "The person prefers afternoon updates.",
                    confidence: 0.9,
                    evidenceIDs: ["invented:evidence"],
                    sourceTurnRecordIDs: [UUID()]
                )
            ]
        )
        XCTAssertThrowsError(try L1SituationFrameValidator().validate(frame, for: request)) { error in
            guard case let .invalidResponse(failures) = error as? L1InferenceError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(failures.contains("memory proposal evidence must reference request evidence"))
            XCTAssertTrue(failures.contains("memory proposal references an unavailable conversation turn"))
        }
    }

    func testRecognizedIdentityRequestDoesNotRequireASpeechDecision() throws {
        let person = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 1_000,
            recognitionConfidence: 0.93,
            availableActions: [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            presentEntityIDs: [person],
            socialOpportunity: opportunity
        )
        let frame = L1SituationFrame(
            cycleID: request.cycleID,
            summary: "Continue observing without interruption.",
            uncertainty: 0.15,
            evidenceIDs: request.evidenceIDs,
            socialDecision: nil
        )
        XCTAssertNoThrow(try L1SituationFrameValidator().validate(frame, for: request))
    }

    func testGemmaRejectsPurposeFreeGreetingOpening() {
        let person = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 1_000,
            recognitionConfidence: 0.94,
            availableActions: [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            presentEntityIDs: [person],
            socialOpportunity: opportunity
        )
        let json = Data("""
        ```json
        {
          "summary": "A short greeting is appropriate.",
          "uncertainty": 0.2,
          "evidence_ids": ["identity:1"],
          "action": "spoken_opening",
          "confidence": 0.81,
          "rationale": "The person has remained present and is not speaking.",
          "opening": {"kind": "greeting"}
        }
        ```
        """.utf8)

        XCTAssertThrowsError(try L1SituationResponseDecoder.decode(json, for: request))
    }

    func testGemmaJSONRejectsAnUnspecifiedOpeningAction() {
        let person = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 1_000,
            recognitionConfidence: 0.94,
            availableActions: [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["scene:1", "turn:1"],
            beliefSummary: "A familiar person is seated and focused on a task.",
            presentEntityIDs: [person],
            socialOpportunity: opportunity
        )
        let json = Data("""
        {
          "summary": "Unbounded social content.",
          "uncertainty": 0.3,
          "evidence_ids": ["scene:1"],
          "opening": {"kind": "greeting"}
        }
        """.utf8)

        XCTAssertThrowsError(try L1SituationResponseDecoder.decode(json, for: request))
    }

    func testGemmaOpeningSelectsAnInformationMotiveWithNaturalWording() throws {
        let person = UUID()
        let motiveID = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 1_000,
            recognitionConfidence: 0.94,
            availableActions: [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            presentEntityIDs: [person],
            informationNeeds: [
                L1InformationNeed(
                    motiveID: motiveID,
                    source: .retainedMemoryGap,
                    informationGoal: "Learn whether the appointment went well.",
                    expectedInformationGain: 0.8
                )
            ],
            socialOpportunity: opportunity
        )
        let approved = Data("""
        {
          "summary": "A brief question is appropriate.",
          "uncertainty": 0.2,
          "evidence_ids": ["identity:1"],
          "action": "spoken_opening",
          "confidence": 0.8,
          "rationale": "The person is present.",
          "opening": {"kind": "question", "motive_id": "\(motiveID.uuidString)", "text": "How was your appointment?"}
        }
        """.utf8)
        XCTAssertEqual(
            try L1SituationResponseDecoder.decode(approved, for: request).socialDecision?.openingContent,
            .question(motiveID: motiveID, text: "How was your appointment?")
        )

        let unrelatedMotive = Data("""
        {
          "summary": "A brief question is appropriate.",
          "uncertainty": 0.2,
          "evidence_ids": ["identity:1"],
          "action": "spoken_opening",
          "confidence": 0.8,
          "rationale": "The person is present.",
          "opening": {"kind": "question", "motive_id": "\(UUID().uuidString)", "text": "How was your appointment?"}
        }
        """.utf8)
        XCTAssertThrowsError(try L1SituationResponseDecoder.decode(unrelatedMotive, for: request))
    }

    func testRollingThoughtStateRetainsOnlyGroundedMotives() throws {
        let person = UUID()
        let motiveID = UUID()
        let opportunity = L1SocialOpportunity(
            entityID: person,
            observedAtNS: 1_000,
            recognitionConfidence: 0.94,
            availableActions: [.remainSilent, .nonverbalInvitation, .spokenOpening]
        )
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 10),
            evidenceIDs: ["identity:1"],
            beliefSummary: "A recognized person is present.",
            presentEntityIDs: [person],
            informationNeeds: [
                L1InformationNeed(
                    motiveID: motiveID,
                    source: .initialSocialOrientation,
                    informationGoal: "Understand whether this person wants to engage.",
                    expectedInformationGain: 0.7
                )
            ],
            socialOpportunity: opportunity
        )
        let json = Data("""
        {
          "summary": "The person is present but may be occupied.",
          "uncertainty": 0.3,
          "evidence_ids": ["identity:1"],
          "thought_state": {
            "social_availability": 0.58,
            "curiosity_pressure": 0.71,
            "interruption_cost": 0.42,
            "relationship_uncertainty": 0.93,
            "active_motive_ids": ["\(motiveID.uuidString)"],
            "working_hypothesis": "A brief, low-pressure opening may be welcome if attention remains available."
          },
          "action": "remain_silent",
          "confidence": 0.72,
          "rationale": "Current evidence does not yet justify interrupting.",
          "opening": null
        }
        """.utf8)
        let frame = try L1SituationResponseDecoder.decode(json, for: request)
        XCTAssertEqual(frame.thoughtState?.activeMotiveIDs, [motiveID])
        XCTAssertEqual(frame.thoughtState?.curiosityPressure, 0.71)

        let invented = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(
            of: motiveID.uuidString,
            with: UUID().uuidString
        ).utf8)
        XCTAssertThrowsError(try L1SituationResponseDecoder.decode(invented, for: request))
    }

    func testMemoryProposalsAreDecoded() throws {
        let turnID = UUID()
        let request = L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 1),
            evidenceIDs: ["scene:1", "turn:1"],
            beliefSummary: "A familiar person is present.",
            recentConversation: [
                L1ConversationContext(
                    turnRecordID: turnID,
                    role: .user,
                    rawText: "Please remember my update preference."
                )
            ]
        )
        let json = Data("""
        {
          "summary": "The person mentioned an update preference.",
          "uncertainty": 0.2,
          "evidence_ids": ["scene:1"],
          "memory_proposals": [
            {
              "kind": "person_fact",
              "summary": "Prefers evening update check-ins.",
              "confidence": 0.85,
              "evidence_ids": ["scene:1"],
              "source_turn_record_ids": ["\(turnID.uuidString)"]
            },
            {
              "kind": "open_question",
              "summary": "What update cadence does this person prefer?",
              "confidence": 0.6,
              "evidence_ids": ["scene:1"]
            }
          ]
        }
        """.utf8)
        let frame = try L1SituationResponseDecoder.decode(json, for: request)
        XCTAssertEqual(frame.memoryProposals.count, 2)
        XCTAssertEqual(frame.memoryProposals[0].kind, .personFact)
        XCTAssertEqual(frame.memoryProposals[0].summary, "Prefers evening update check-ins.")
        XCTAssertEqual(frame.memoryProposals[0].confidence, 0.85)
        XCTAssertEqual(frame.memoryProposals[0].sourceTurnRecordIDs, [turnID])
        XCTAssertEqual(frame.memoryProposals[1].kind, .openQuestion)
        XCTAssertEqual(frame.memoryProposals[1].evidenceIDs, ["scene:1"])
    }

    private func fixtureRequest() -> L1SituationRequest {
        L1SituationRequest(
            observedAt: Date(timeIntervalSince1970: 1),
            evidenceIDs: ["scene:1", "turn:1"],
            beliefSummary: "A familiar person is seated and focused on a task.",
            recentConversation: [
                L1ConversationContext(
                    turnRecordID: UUID(),
                    role: .user,
                    rawText: "Please remember my update preference."
                )
            ]
        )
    }
}
#endif
