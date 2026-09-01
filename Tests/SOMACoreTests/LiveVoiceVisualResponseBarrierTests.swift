import Foundation
import Testing
@testable import SOMACore

@Suite struct LiveVoiceVisualResponseBarrierTests {
    @Test func activeProvisionalResponseIsCancelledBeforeEvidence() {
        var barrier = LiveVoiceVisualResponseBarrier(
            transcript: "지금 뭐 보여?"
        )

        #expect(barrier.initialActions == [.closeOutput, .acquireEvidence, .cancelResponse])
        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.suppressesAssistantPresentation)
        #expect(barrier.observeProvisionalResponseSettled(cancellationAcknowledged: true) == [.requestResponse])
        #expect(barrier.observeResponseEnded(responseID: "old").isEmpty)
        #expect(barrier.phase == .awaitingReplacementResponse)
        #expect(barrier.observeResponseStarted(responseID: "replacement").isEmpty)
        #expect(barrier.suppressesAssistantPresentation)
        #expect(barrier.observePresentationStarted(responseID: "replacement") == [.openOutput])
        #expect(!barrier.suppressesAssistantPresentation)
    }

    @Test func evidenceReadyWithoutProvisionalResponseRequestsOneResponse() {
        var barrier = LiveVoiceVisualResponseBarrier(
            transcript: "Can you see me?"
        )

        #expect(barrier.initialActions == [.closeOutput, .acquireEvidence, .cancelResponse])
        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.observeProvisionalResponseSettled(cancellationAcknowledged: true) == [.requestResponse])
        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.observeResponseStarted(responseID: "replacement").isEmpty)
        #expect(barrier.observePresentationStarted(responseID: "replacement") == [.openOutput])
        #expect(barrier.observePresentationStarted(responseID: "replacement").isEmpty)
    }

    @Test func responseCreatedDuringCaptureIsCancelledThenReplaced() {
        var barrier = LiveVoiceVisualResponseBarrier(
            transcript: "아기 보여",
            provisionalResponseID: "provisional"
        )

        #expect(barrier.observeResponseStarted().isEmpty)
        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.observeResponseEnded(responseID: "provisional") == [.requestResponse])
        #expect(barrier.observeResponseStarted(responseID: "replacement").isEmpty)
        #expect(barrier.observePresentationStarted(responseID: "replacement") == [.openOutput])
    }

    @Test func evidenceCannotReleaseAnUnsettledAutomaticResponse() {
        var barrier = LiveVoiceVisualResponseBarrier(
            participantTurnSequence: 9,
            transcript: "What am I doing?"
        )

        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.phase == .settlingProvisionalResponse)
        #expect(barrier.observeResponseStarted(responseID: "provisional").isEmpty)
        #expect(barrier.suppressesAssistantPresentation)
        #expect(barrier.observeProvisionalResponseSettled(responseID: "unrelated").isEmpty)
        #expect(barrier.observeProvisionalResponseSettled(responseID: "provisional") == [.requestResponse])
        #expect(barrier.observeResponseStarted(responseID: "replacement").isEmpty)
        #expect(barrier.observePresentationStarted(responseID: "provisional").isEmpty)
        #expect(barrier.observePresentationStarted(responseID: "replacement") == [.openOutput])
    }

    @Test func identicalTranscriptStillCarriesParticipantTurnIdentity() {
        let first = LiveVoiceVisualResponseBarrier(
            participantTurnSequence: 41,
            transcript: "Can you see me?"
        )
        let second = LiveVoiceVisualResponseBarrier(
            participantTurnSequence: 42,
            transcript: "Can you see me?"
        )

        #expect(first.transcript == second.transcript)
        #expect(first.participantTurnSequence != second.participantTurnSequence)
    }

    @Test func lateEventsFromSupersededResponseCannotReleaseCurrentTurn() {
        var barrier = LiveVoiceVisualResponseBarrier(
            participantTurnSequence: 52,
            transcript: "What am I holding?",
            provisionalResponseID: "turn-b-provisional"
        )

        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.observeResponseEnded(responseID: "turn-a-provisional").isEmpty)
        #expect(!barrier.provisionalResponseSettled)
        #expect(barrier.observeResponseEnded(responseID: "turn-b-provisional") == [.requestResponse])
        #expect(barrier.observeResponseStarted(responseID: "turn-b-replacement").isEmpty)
        #expect(barrier.observePresentationStarted(responseID: "turn-a-replacement").isEmpty)
        #expect(barrier.observePresentationStarted(responseID: "turn-b-replacement") == [.openOutput])
    }

    @Test func uncorrelatedResponseCannotClaimReplacementOwnership() {
        var barrier = LiveVoiceVisualResponseBarrier(transcript: "지금 뭐 보여?")

        #expect(barrier.observeEvidenceCommitted().isEmpty)
        #expect(barrier.observeProvisionalResponseSettled(cancellationAcknowledged: true) == [.requestResponse])
        #expect(barrier.observeResponseStarted(responseID: nil).isEmpty)
        #expect(barrier.phase == .awaitingReplacementResponse)
        #expect(barrier.observePresentationStarted(responseID: "unknown").isEmpty)
        #expect(barrier.suppressesAssistantPresentation)
    }
}
