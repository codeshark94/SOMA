#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class L1SituationStreamTests: XCTestCase {
    func testGemmaOwnsBothL1WorkloadsWithoutChangingTheirContract() throws {
        let configuration = L1ModelConfiguration.gemma31
        XCTAssertEqual(configuration.model, "gemma4:31b-cloud")
        XCTAssertEqual(configuration.deadlineMilliseconds(for: .situation), 8_000)
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
        let request = fixtureRequest()
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
