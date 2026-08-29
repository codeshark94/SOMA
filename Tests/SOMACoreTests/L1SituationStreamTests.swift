#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class L1SituationStreamTests: XCTestCase {
    func testCanonicalProfileMotiveUsesMaterializedFactsInsteadOfRecentEvents() {
        let personID = UUID()
        let unknown = PersonContextSnapshot(
            personEntityID: personID,
            preferredLanguageTag: "ko",
            proactiveContactPreference: .allowed,
            rapport: nil,
            facts: [:]
        )
        XCTAssertFalse(L1InformationMotiveSource.initialSocialOrientation.isSatisfied(by: unknown))

        let known = PersonContextSnapshot(
            personEntityID: personID,
            preferredLanguageTag: "ko",
            proactiveContactPreference: .allowed,
            rapport: nil,
            facts: [
                "preferred_name": "승엽",
                "interests": "embodied artificial intelligence",
            ]
        )
        XCTAssertTrue(L1InformationMotiveSource.initialSocialOrientation.isSatisfied(by: known))
        XCTAssertTrue(L1InformationMotiveSource.interestDiscovery.isSatisfied(by: known))
        XCTAssertFalse(L1InformationMotiveSource.retainedMemoryGap.isSatisfied(by: known))
    }

    func testProactiveOpeningControllerEventPreservesSuppliedLanguageAndRejectsBlankText() {
        let opening = "승엽님, 평소에 특별히 관심 있거나 즐겨 하시는 취미가 있으신가요?"
        let event = LiveVoiceOpeningControllerEvent.make(opening: opening, languageTag: "ko-KR")
        XCTAssertEqual(event, """
        ⟦SOMA_EXACT_OPENING language=ko-kr delivery=once_then_listen⟧
        \(opening)
        ⟦/SOMA_EXACT_OPENING⟧
        """)
        XCTAssertNil(LiveVoiceOpeningControllerEvent.make(opening: " \n ", languageTag: "ko"))
    }

    func testLiveVoiceConversationFrameDoesNotAssumeEveryContactIsAServiceRequest() {
        let participantOrigin = LiveVoiceConversationFrame.originInstruction(
            isProactiveSession: false
        )
        XCTAssertTrue(participantOrigin.contains("contact alone is not evidence of a service request"))
        XCTAssertTrue(participantOrigin.contains("unfinished fragment"))
        XCTAssertTrue(LiveVoiceConversationFrame.socialStanceInstruction.contains(
            "Enter assistance mode only when the participant actually expresses a request"
        ))

        let proactiveOrigin = LiveVoiceConversationFrame.originInstruction(
            isProactiveSession: true
        )
        XCTAssertTrue(proactiveOrigin.contains("specific L1 social purpose"))
        XCTAssertTrue(proactiveOrigin.contains("Never reset into a generic service frame"))
    }

    func testContactEpisodeRecordsOnlyObservedResponseAndClosure() {
        var episode = L1ConversationContactEpisode()
        XCTAssertFalse(episode.observeFinalizedTurn(role: .assistant))
        XCTAssertTrue(episode.observeFinalizedTurn(role: .user))
        XCTAssertFalse(episode.observeFinalizedTurn(role: .user))
        XCTAssertEqual(episode.closureKind(interrupted: false), .conversationEnded)
        XCTAssertEqual(episode.closureKind(interrupted: true), .conversationInterrupted)
        XCTAssertEqual(
            L1ConversationContactEpisode().closureKind(interrupted: false),
            .conversationEndedWithoutParticipantTurn
        )
    }

    func testGemmaConfigurationKeepsSituationAndConsolidationBudgetsDistinct() {
        let configuration = L1ModelConfiguration.gemma31
        XCTAssertEqual(configuration.model, "gemma4:31b-cloud")
        XCTAssertEqual(configuration.deadlineMilliseconds(for: .situation), 20_000)
        XCTAssertEqual(configuration.deadlineMilliseconds(for: .memoryConsolidation), 60_000)
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

    func testPlaceAffiliationContextKeepsPlaceEvidenceSeparateUntilConfirmed() {
        let placeID = UUID()
        let unresolved = L1PlaceAffiliationContext(
            spaceID: placeID,
            label: "  studio  ",
            isStable: true,
            unassignedObservationCount: 3
        )
        XCTAssertEqual(unresolved.label, "studio")
        XCTAssertTrue(unresolved.affiliationUnresolved)

        let confirmed = L1PlaceAffiliationContext(
            spaceID: placeID,
            label: "studio",
            isStable: true,
            ownerEntityID: UUID()
        )
        XCTAssertFalse(confirmed.affiliationUnresolved)
        XCTAssertEqual(
            L1SpatialContext(panoramaAvailable: false, placeAffiliation: unresolved).placeAffiliation,
            unresolved
        )
    }

    func testSocialRapportInferenceRewardsReciprocalRecentContact() {
        let now = Date(timeIntervalSince1970: 50_000)
        let reciprocal = L1SocialRapportEstimator.infer(from: [
            .init(kind: .conversationOpened, occurredAt: now),
            .init(kind: .participantResponded, occurredAt: now),
            .init(kind: .conversationEnded, occurredAt: now),
        ], at: now)
        let unanswered = L1SocialRapportEstimator.infer(from: [
            .init(kind: .conversationOpened, occurredAt: now),
            .init(kind: .conversationEndedWithoutParticipantTurn, occurredAt: now),
        ], at: now)

        XCTAssertGreaterThan(reciprocal?.familiarity ?? 0, unanswered?.familiarity ?? 0)
        XCTAssertGreaterThan(reciprocal?.interactionComfort ?? 0, unanswered?.interactionComfort ?? 0)
        XCTAssertGreaterThan(reciprocal?.communicationAlignment ?? 0, unanswered?.communicationAlignment ?? 0)
    }

    func testMemoryProposalRemainsEvidenceBounded() {
        let proposal = L1MemoryProposal(
            kind: .openQuestion,
            summary: String(repeating: "x", count: 5_000),
            confidence: 0.8,
            evidenceIDs: ["event:1"],
            sourceTurnRecordIDs: [UUID()]
        )
        XCTAssertEqual(proposal.summary.count, 4_096)
        XCTAssertEqual(proposal.evidenceIDs, ["event:1"])
        XCTAssertEqual(proposal.sourceTurnRecordIDs.count, 1)
    }
}
#endif
