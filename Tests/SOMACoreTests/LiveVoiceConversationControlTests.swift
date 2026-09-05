import Testing
@testable import SOMACore

struct LiveVoiceConversationControlTests {
    private let classifier = LiveVoiceConversationControlClassifier()

    @Test
    func explicitKoreanVoiceTerminationIsOwnedByTheHost() {
        #expect(classifier.classify("음성 끊어") == .endConversation)
        #expect(classifier.classify("음성 세션 종료해줘") == .endConversation)
        #expect(classifier.classify("말 그만해") == .endConversation)
        #expect(classifier.classify("종료 안 됐잖아. 종료할 줄 몰라?") == .endConversation)
    }

    @Test
    func negatedOrDescriptiveLanguageDoesNotEndTheConversation() {
        #expect(classifier.classify("음성 세션 종료하지 마") == nil)
        #expect(classifier.classify("대화를 끝내지 말고 계속해") == nil)
        #expect(classifier.classify("음성 세션 종료 기능이 어떻게 작동해?") == nil)
        #expect(classifier.classify("Please don't stop the voice session") == nil)
    }

    @Test
    func explicitEnglishAndCjkControlsAreRecognized() {
        #expect(classifier.classify("Stop the voice session") == .endConversation)
        #expect(classifier.classify("Please end this conversation") == .endConversation)
        #expect(classifier.classify("音声セッションを終了して") == .endConversation)
        #expect(classifier.classify("请结束语音会话") == .endConversation)
    }

    @Test
    func OrdinaryConversationIsNotAControlCommand() {
        #expect(classifier.classify("우리 태림이한테 재밌는 옛날이야기 해줘") == nil)
        #expect(classifier.classify("What happens at the end of the story?") == nil)
        #expect(classifier.classify("") == nil)
    }

    @Test
    func serverParticipantEvidenceDoesNotDependOnTranscriptPayloadShape() {
        #expect(LiveVoiceRealtimeEventSemantics.confirmsParticipantInput(
            type: "input_audio_buffer.speech_started"
        ))
        #expect(LiveVoiceRealtimeEventSemantics.confirmsParticipantInput(
            type: "input_transcript.added"
        ))
        #expect(LiveVoiceRealtimeEventSemantics.confirmsParticipantInput(
            type: "thread/realtime/transcript/done"
        ) == false)
        #expect(LiveVoiceRealtimeEventSemantics.confirmsParticipantInput(
            type: "input_transcript.failed"
        ) == false)
        #expect(LiveVoiceRealtimeEventSemantics.confirmsParticipantInput(
            type: "turn.created"
        ) == false)
    }

    @Test
    func framelessNestedTranscriptAdditionIsProvisional() throws {
        let event: [String: Any] = [
            "type": "input_transcript.added",
            "item": [
                "id": "input-item-a",
                "text": "  오늘   시장 동향을 조사해 줘.  ",
                "user_bidi_turn_id": "bidi-turn-a",
            ],
        ]
        let transcript = try #require(LiveVoiceWireTranscriptParser.parse(event))
        #expect(transcript.text == "오늘 시장 동향을 조사해 줘.")
        #expect(transcript.itemID == "input-item-a")
        #expect(transcript.turnID == "bidi-turn-a")
        #expect(transcript.source == .inputTranscript)
        #expect(transcript.authoritative == false)
    }

    @Test
    func framelessDelegationCarriesAuthoritativeTranscript() throws {
        let event: [String: Any] = [
            "type": "delegation.created",
            "item": [
                "id": "delegation-a",
                "target": "client",
                "input_transcript": "오늘 시장 동향을 조사해 줘.",
                "user_bidi_turn_id": "bidi-turn-a",
            ],
        ]
        let transcript = try #require(LiveVoiceWireTranscriptParser.parse(event))
        #expect(transcript.text == "오늘 시장 동향을 조사해 줘.")
        #expect(transcript.itemID == "delegation-a")
        #expect(transcript.turnID == "bidi-turn-a")
        #expect(transcript.source == .delegation)
        #expect(transcript.authoritative)
    }

    @Test
    func currentFramelessDelegationConcatenatesInputTextContent() throws {
        let event: [String: Any] = [
            "type": "delegation.created",
            "item": [
                "id": "delegation-current",
                "type": "delegation",
                "target": "client",
                "content": [
                    ["type": "input_text", "text": "오늘 시장 동향을 "],
                    ["type": "input_text", "text": "조사해 줘."],
                    ["type": "output_text", "text": "ignored"],
                ],
            ],
        ]
        let transcript = try #require(LiveVoiceWireTranscriptParser.parse(event))
        #expect(transcript.text == "오늘 시장 동향을 조사해 줘.")
        #expect(transcript.itemID == "delegation-current")
        #expect(transcript.source == .delegation)
        #expect(transcript.authoritative)
    }

    @Test
    func localTransportPreparationDoesNotWaitForRemoteThread() {
        #expect(LiveVoiceRealtimeStartupPolicy.permitsTransportPreparation(
            webViewReady: true,
            transportAlreadyStarted: false
        ))
        #expect(LiveVoiceRealtimeStartupPolicy.permitsTransportPreparation(
            webViewReady: false,
            transportAlreadyStarted: false
        ) == false)
        #expect(LiveVoiceRealtimeStartupPolicy.permitsTransportPreparation(
            webViewReady: true,
            transportAlreadyStarted: true
        ) == false)
    }

    @Test
    func remoteRealtimeStartsAsSoonAsOfferIsReady() {
        #expect(LiveVoiceRealtimeStartupPolicy.permitsRealtimeStart(
            offerReady: true,
            realtimeAlreadyStarted: false
        ))
        #expect(LiveVoiceRealtimeStartupPolicy.permitsRealtimeStart(
            offerReady: false,
            realtimeAlreadyStarted: false
        ) == false)
        #expect(LiveVoiceRealtimeStartupPolicy.permitsRealtimeStart(
            offerReady: true,
            realtimeAlreadyStarted: true
        ) == false)
    }

    @Test
    func openingAudioCanQueueBeforeRemoteThreadExists() {
        #expect(LiveVoiceRealtimeStartupPolicy.permitsAudioEnqueue(webViewReady: true))
        #expect(LiveVoiceRealtimeStartupPolicy.permitsAudioEnqueue(webViewReady: false) == false)
    }

    @Test
    func staleResponseCompletionCannotCloseNewerBargeInTurn() {
        var tracker = LiveVoiceResponseTurnTracker()
        let first = tracker.beginParticipantTurn()
        #expect(first == 1)
        #expect(tracker.observeResponseStarted(responseID: "response-a") == first)

        let second = tracker.beginParticipantTurn()
        #expect(second == 2)
        #expect(tracker.observeResponseStarted(responseID: "response-b") == second)

        #expect(tracker.completeResponse(responseID: "response-a") == .stale(
            generation: first,
            currentGeneration: second
        ))
        #expect(tracker.participantTurnOpen)
        #expect(tracker.completeResponse(responseID: "response-b") == .current(
            generation: second
        ))
        #expect(tracker.participantTurnOpen == false)
    }

    @Test
    func duplicateResponseStartRetainsOriginalTurnBinding() {
        var tracker = LiveVoiceResponseTurnTracker()
        let first = tracker.beginParticipantTurn()
        #expect(tracker.observeResponseStarted(responseID: "response-a") == first)
        _ = tracker.beginParticipantTurn()
        #expect(tracker.observeResponseStarted(responseID: "response-a") == first)
    }

    @Test
    func uncorrelatedCompletionCannotCloseCurrentTurn() {
        var tracker = LiveVoiceResponseTurnTracker()
        _ = tracker.beginParticipantTurn()
        #expect(tracker.completeResponse(responseID: nil) == .uncorrelated)
        #expect(tracker.completeResponse(responseID: "unknown") == .uncorrelated)
        #expect(tracker.participantTurnOpen)
    }

}
