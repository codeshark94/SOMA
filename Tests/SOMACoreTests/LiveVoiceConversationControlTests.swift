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
    func localTransportPreparationOverlapsCapabilitySnapshot() {
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsTransportPreparation(
            webViewReady: true,
            threadReady: true,
            transportAlreadyStarted: false
        ))
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsTransportPreparation(
            webViewReady: true,
            threadReady: false,
            transportAlreadyStarted: false
        ) == false)
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsTransportPreparation(
            webViewReady: true,
            threadReady: true,
            transportAlreadyStarted: true
        ) == false)
    }

    @Test
    func remoteRealtimeWaitsForOfferAndBoundedCapabilitySnapshot() {
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsRealtimeStart(
            offerReady: true,
            capabilityVerificationFinished: false,
            realtimeAlreadyStarted: false
        ) == false)
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsRealtimeStart(
            offerReady: true,
            capabilityVerificationFinished: true,
            realtimeAlreadyStarted: false
        ))
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsRealtimeStart(
            offerReady: false,
            capabilityVerificationFinished: true,
            realtimeAlreadyStarted: false
        ) == false)
        #expect(LiveVoiceEmbodimentStartupPolicy.permitsRealtimeStart(
            offerReady: true,
            capabilityVerificationFinished: true,
            realtimeAlreadyStarted: true
        ) == false)
    }

    @Test
    func openingAudioWaitsForRemoteSessionAndInputTrackThenPlaysOnce() {
        var gate = LiveVoiceOpeningAudioPlayoutGate()
        let beforeActive = gate.authorizePlayoutIfReady(hasBufferedAudio: true)
        #expect(beforeActive == false)
        gate.observeSessionActive()
        let beforeInput = gate.authorizePlayoutIfReady(hasBufferedAudio: true)
        #expect(beforeInput == false)
        gate.observeInputTrackReady()
        let empty = gate.authorizePlayoutIfReady(hasBufferedAudio: false)
        #expect(empty == false)
        let submitted = gate.authorizePlayoutIfReady(hasBufferedAudio: true)
        #expect(submitted)
        let duplicate = gate.authorizePlayoutIfReady(hasBufferedAudio: true)
        #expect(duplicate == false)
    }

    @Test
    func openingAudioAddsAStableServerVADOffsetBoundary() {
        #expect(LiveVoiceOpeningAudioPolicy.trailingSilenceSampleCount(sampleRate: 48_000) == 23_040)
        #expect(LiveVoiceOpeningAudioPolicy.trailingSilenceSampleCount(sampleRate: 24_000) == 11_520)
        #expect(LiveVoiceOpeningAudioPolicy.trailingSilenceSampleCount(sampleRate: 7_999) == nil)
    }

    @Test
    func oneParticipantTurnHasOneAudibleResponseOwner() {
        #expect(LiveVoiceHandoffResponsePolicy.disposition(
            hasAgentMessage: true,
            realtimeResponseSpoken: false,
            successfulExternalDelegation: false
        ) == .appendFinalSpeech)
        #expect(LiveVoiceHandoffResponsePolicy.disposition(
            hasAgentMessage: true,
            realtimeResponseSpoken: true,
            successfulExternalDelegation: false
        ) == .retainExistingRealtimeResponse)
        #expect(LiveVoiceHandoffResponsePolicy.disposition(
            hasAgentMessage: true,
            realtimeResponseSpoken: false,
            successfulExternalDelegation: true
        ) == .externalDelegationOwnsResponse)
        #expect(LiveVoiceHandoffResponsePolicy.disposition(
            hasAgentMessage: false,
            realtimeResponseSpoken: false,
            successfulExternalDelegation: false
        ) == .noResponse)
    }
}
