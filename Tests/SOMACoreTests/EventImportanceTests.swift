#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class EventImportanceTests: XCTestCase {
    func testDistributionNormalizesAndHumanInteractionRequiresAuthorization() {
        let model = EventImportanceModel()
        let novelty = decision(
            model: model,
            features: EventImportanceFeatures(
                novelty: 1,
                predictionError: 0.9,
                informationGain: 0.9,
                persistence: 0.8
            )
        )
        XCTAssertEqual(novelty.policyReason, .humanInteractionNotAuthorized)
        XCTAssertEqual(novelty.distribution.requestHumanInteraction, 0)
        XCTAssertEqual(novelty.recommendedRoute, .wakeL1)
        XCTAssertEqual(novelty.distribution.sum, 1, accuracy: 1e-12)
    }

    func testExplicitContactOpensInteractionAndBuildsL1ContextInParallel() {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 0.95,
                socialSalience: 0.9,
                interruptionCost: 1,
                recentWakePressure: 1,
                humanPresence: 0.95
            )
        )
        XCTAssertEqual(result.policyReason, .explicitHumanContact)
        XCTAssertEqual(result.recommendedRoute, .requestHumanInteraction)
        XCTAssertGreaterThan(result.distribution.requestHumanInteraction, 0)
        XCTAssertEqual(result.sample(unitInterval: 0), .requestHumanInteraction)
        XCTAssertTrue(result.dispatch.openHumanInteraction)
        XCTAssertTrue(result.dispatch.wakeL1Context)
        XCTAssertTrue(result.dispatch.bypassesL1Admission)
    }

    func testExplicitContactWakeAndFinalTranscriptHandoffToCodex() throws {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 0.95,
                socialSalience: 0.9,
                crossModalCorroboration: 0.95,
                humanPresence: 0.95
            )
        )
        let wake = try HumanInteractionWakeRequest(
            decision: result,
            audioPreRollMilliseconds: 900
        )
        XCTAssertTrue(wake.bypassesL1Admission)
        XCTAssertTrue(wake.prepareL1ContextInParallel)

        let turn = try CodexInteractionTurn(
            interactionID: "interaction-1",
            turnID: "turn-1",
            transcript: "안녕, what are you looking at?",
            languageTag: "und",
            speechStartedAtNS: 1_000,
            transcriptFinalizedAtNS: 2_000,
            evidenceIDs: wake.evidenceIDs,
            contextPacketReference: "context:interaction-1:1"
        )
        let encoded = try JSONEncoder().encode(turn)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("안녕, what are you looking at?"))
        XCTAssertFalse(json.lowercased().contains("audio"))
        XCTAssertEqual(try JSONDecoder().decode(CodexInteractionTurn.self, from: encoded), turn)
    }

    func testSpeechTurnRequiresAuthorizedWakeAndClosesOnVoiceOffset() throws {
        var segmenter = SpeechTurnSegmenter()
        XCTAssertNil(segmenter.observe(voiceActive: true, at: 1_000_000_000))

        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 0.9,
                socialSalience: 0.9,
                crossModalCorroboration: 0.9,
                humanPresence: 0.9
            )
        )
        let wake = try HumanInteractionWakeRequest(
            decision: result,
            audioPreRollMilliseconds: 900
        )
        let started = segmenter.observe(
            voiceActive: true,
            at: 2_000_000_000,
            authorizedWake: wake
        )
        guard case .started(let start) = started else {
            return XCTFail("authorized voice did not start a turn")
        }
        XCTAssertEqual(start.speechStartedAtNS, 1_740_000_000)
        XCTAssertNil(segmenter.observe(voiceActive: true, at: 2_500_000_000))

        let finished = segmenter.observe(voiceActive: false, at: 3_000_000_000)
        guard case .finished(let finish) = finished else {
            return XCTFail("voice offset did not finish the turn")
        }
        XCTAssertEqual(finish.reason, .voiceOffset)
        XCTAssertEqual(finish.speechStartedAtNS, start.speechStartedAtNS)
        XCTAssertEqual(finish.speechEndedAtNS, 3_000_000_000)
    }

    func testSpeechTurnIsBoundedAndRearmsAfterCooldown() throws {
        var segmenter = SpeechTurnSegmenter(configuration: .init(
            analysisLookbackMilliseconds: 100,
            maximumTurnMilliseconds: 1_000,
            rearmMilliseconds: 500
        ))
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(explicitContact: 1, humanPresence: 1)
        )
        let wake = try HumanInteractionWakeRequest(decision: result, audioPreRollMilliseconds: 500)
        XCTAssertNotNil(segmenter.observe(voiceActive: true, at: 1_000_000_000, authorizedWake: wake))

        let bounded = segmenter.observe(voiceActive: true, at: 1_900_000_000)
        guard case .finished(let finish) = bounded else {
            return XCTFail("maximum utterance duration was not enforced")
        }
        XCTAssertEqual(finish.reason, .maximumDuration)
        XCTAssertNil(segmenter.observe(voiceActive: true, at: 2_300_000_000, authorizedWake: wake))
        XCTAssertNotNil(segmenter.observe(voiceActive: true, at: 2_400_000_000, authorizedWake: wake))
    }

    func testCodexAccountBridgeBuildsBoundedScopedPromptAndParsesCLIJSONL() throws {
        let turn = try CodexInteractionTurn(
            interactionID: "interaction-account",
            turnID: "turn-account",
            transcript: "지금 뭘 보고 있어?",
            languageTag: "ko",
            speechStartedAtNS: 10,
            transcriptFinalizedAtNS: 20,
            evidenceIDs: ["vision:face", "voice:onset"],
            contextPacketReference: "context:account"
        )
        let context = try CodexInteractionContext(
            situationSummary: "A known human is centered in the current view.",
            identityReference: "person:local-owner",
            preferredLanguageTag: "ko",
            languageStartInstruction: "한국어로 자연스럽게 대답하세요.",
            rapportSummary: "familiar",
            activeTaskSummaries: ["Finish the SOMA interaction bridge."],
            memorySummaries: ["The user prefers concise Korean responses."],
            embodimentSummary: "L0 currently owns face fixation."
        )
        let request = try CodexAccountTurnRequest(turn: turn, context: context)
        try request.validate()
        let prompt = CodexAccountPromptBuilder.prompt(for: request)
        XCTAssertTrue(prompt.contains("지금 뭘 보고 있어?"))
        XCTAssertTrue(prompt.contains("person:local-owner"))
        XCTAssertTrue(prompt.contains("Preferred response language: ko"))
        XCTAssertTrue(prompt.contains("한국어로 자연스럽게 대답하세요."))
        XCTAssertTrue(prompt.contains("preceding turns in this same interaction"))
        XCTAssertFalse(prompt.lowercased().contains("raw audio"))

        let jsonl = """
        {"type":"thread.started","thread_id":"thread-123"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"당신을 보고 있어요."}}
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":12,"reasoning_output_tokens":2}}
        """
        let result = try CodexCLIJSONLParser.parse(Data(jsonl.utf8))
        XCTAssertEqual(result.threadID, "thread-123")
        XCTAssertEqual(result.assistantText, "당신을 보고 있어요.")
        XCTAssertEqual(result.usage?.cachedInputTokens, 20)
    }

    func testCompletedPersonMemoryMissionIsOmittedFromLiveContext() throws {
        let personID = UUID()
        let completed = PersonContextMission(
            requiredKeys: ["preferred_name"],
            missingRequiredKeys: [],
            recommendedKeys: ["relationship_context"]
        )
        let context = try CodexInteractionContext(
            personEntityID: personID,
            sessionCapability: UUID().uuidString.lowercased(),
            interactionAuthority: .participant,
            personMemoryMission: completed
        )
        XCTAssertNil(context.personMemoryMission)
        XCTAssertEqual(context.personEntityID, personID)
        XCTAssertNotNil(context.sessionCapability)
    }

    func testUnrecognizedLiveSpeakerKeepsEmbodimentAuthorityWithoutPersonMemory() throws {
        let context = try CodexInteractionContext(
            personEntityID: UUID(),
            personContextAvailable: false,
            sessionCapability: UUID().uuidString.lowercased(),
            interactionAuthority: .participant,
            personMemoryMission: PersonContextMission(
                requiredKeys: ["preferred_name"],
                missingRequiredKeys: ["preferred_name"],
                recommendedKeys: []
            )
        )
        XCTAssertFalse(context.personContextAvailable)
        XCTAssertNil(context.personMemoryMission)

        let restored = try JSONDecoder().decode(
            CodexInteractionContext.self,
            from: JSONEncoder().encode(context)
        )
        XCTAssertEqual(restored, context)
    }

    func testCodexAccountBridgeRejectsAnInvalidDecodedTurn() throws {
        let json = """
        {"schemaVersion":1,"turn":{"interactionID":"interaction","turnID":"turn","transcript":"   ","speechStartedAtNS":20,"transcriptFinalizedAtNS":10,"evidenceIDs":[]},"context":{"activeTaskSummaries":[],"memorySummaries":[],"privacyScope":"interaction_scoped"}}
        """
        let decoded = try JSONDecoder().decode(CodexAccountTurnRequest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try decoded.validate())
    }

    func testNonHumanNoveltyCannotCreateInteractionWake() {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(novelty: 1, informationGain: 1)
        )
        XCTAssertThrowsError(
            try HumanInteractionWakeRequest(
                decision: result,
                audioPreRollMilliseconds: 900
            )
        )
    }

    func testSafetyRemainsLocalAndCannotOpenHumanInteraction() {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 1,
                urgency: 1,
                safetyRisk: 1,
                humanPresence: 1
            )
        )
        XCTAssertEqual(result.policyReason, .localSafety)
        XCTAssertEqual(result.recommendedRoute, .stayL0)
        XCTAssertEqual(result.distribution.requestHumanInteraction, 0)
        XCTAssertFalse(result.dispatch.openHumanInteraction)
        XCTAssertEqual(result.sample(unitInterval: 0.99), .stayL0)
    }

    func testAcceptedMemoryCuriosityCanOpenInteractionOnlyWithHumanPresent() {
        let absent = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(acceptedMemoryCuriosity: 1)
        )
        XCTAssertEqual(absent.distribution.requestHumanInteraction, 0)

        let present = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                socialSalience: 0.8,
                humanPresence: 0.9,
                acceptedMemoryCuriosity: 1
            )
        )
        XCTAssertEqual(present.policyReason, .acceptedMemoryCuriosity)
        XCTAssertEqual(present.recommendedRoute, .requestHumanInteraction)
        XCTAssertTrue(present.dispatch.openHumanInteraction)
        XCTAssertFalse(present.dispatch.bypassesL1Admission)
    }

    func testBootstrapCorpusAndTemperatureCalibration() throws {
        let examples = try loadBootstrapCorpus()
        let calibration = examples.filter { $0.partition == .calibration }
        let evaluation = examples.filter { $0.partition == .evaluation }
        XCTAssertEqual(calibration.count, 16)
        XCTAssertEqual(evaluation.count, 16)
        let baseline = try EventImportanceEvaluator.evaluate(model: EventImportanceModel(), examples: calibration)
        let temperature = try EventImportanceEvaluator.calibratedTemperature(
            parameters: .bootstrap,
            examples: calibration
        )
        let calibratedParameters = try EventImportanceParameters.bootstrap.withTemperature(temperature)
        let calibrated = try EventImportanceEvaluator.evaluate(
            model: EventImportanceModel(parameters: calibratedParameters),
            examples: calibration
        )
        let heldOut = try EventImportanceEvaluator.evaluate(
            model: EventImportanceModel(parameters: calibratedParameters),
            examples: evaluation
        )
        XCTAssertLessThanOrEqual(calibrated.negativeLogLikelihood, baseline.negativeLogLikelihood + 1e-12)
        XCTAssertEqual(calibrated.unauthorizedHumanInteractionRequests, 0)
        XCTAssertEqual(heldOut.unauthorizedHumanInteractionRequests, 0)
    }

    func testSamplingIsReplayable() {
        let result = decision(model: EventImportanceModel(), features: EventImportanceFeatures())
        XCTAssertEqual(result.sample(unitInterval: 0), .stayL0)
        XCTAssertEqual(result.sample(unitInterval: 0), result.sample(unitInterval: 0))
    }

    func testLegacyInteractionRouteDecodesButNewEncodingIsLayerNeutral() throws {
        let legacy = try JSONDecoder().decode(
            CognitiveRoute.self,
            from: Data("\"request_l2_human\"".utf8)
        )
        XCTAssertEqual(legacy, .requestHumanInteraction)
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self),
            "\"request_human_interaction\""
        )
    }

    func testLegacyThirdLayerEmbodimentAuthorityMigratesToL2() throws {
        let legacy = try JSONDecoder().decode(
            CognitiveControlLayer.self,
            from: Data("\"l3\"".utf8)
        )
        XCTAssertEqual(legacy, .l2)
        XCTAssertEqual(CognitiveControlLayer.allCases, [.l1, .l2])
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self),
            "\"l2\""
        )
    }

    func testFirstConversationRequiresEyeContactOrBotSocialPulse() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate(configuration: .init(
            eyeContactFreshnessMilliseconds: 450,
            socialPulseResponseMilliseconds: 8_000,
            conversationInactivityMilliseconds: 60_000
        ))
        XCTAssertNil(gate.authorizeSpeechOnset(at: start))

        gate.observeEyeContact(at: start)
        XCTAssertEqual(
            gate.authorizeSpeechOnset(at: start + 450_000_000),
            .eyeContact
        )
        XCTAssertNil(gate.authorizeSpeechOnset(at: start + 451_000_000))

        gate.issueSocialPulse(at: start + 1_000_000_000)
        XCTAssertEqual(
            gate.authorizeSpeechOnset(at: start + 1_100_000_000),
            .botInitiatedPulseResponse
        )
        XCTAssertNil(gate.authorizeSpeechOnset(at: start + 1_200_000_000))
    }

    func testOpenedConversationAllowsFollowUpsUntilInactivityExpiry() {
        let start: UInt64 = 2_000_000_000
        var gate = ConversationContactGate(configuration: .init(
            eyeContactFreshnessMilliseconds: 450,
            socialPulseResponseMilliseconds: 8_000,
            conversationInactivityMilliseconds: 60_000
        ))
        gate.markConversationOpened(at: start)
        XCTAssertEqual(
            gate.authorizeSpeechOnset(at: start + 59_999_000_000),
            .activeConversation
        )
        XCTAssertNil(gate.authorizeSpeechOnset(at: start + 60_000_000_000))
    }

    func testLiveVoiceSessionClosesAfterOneMinuteWithoutUserActivity() {
        let start: UInt64 = 1_000_000_000
        var gate = LiveVoiceSessionInactivityGate()
        let initialDeadline = gate.activate(at: start)
        XCTAssertFalse(gate.shouldClose(at: initialDeadline - 1))
        XCTAssertTrue(gate.shouldClose(at: initialDeadline))

        let renewedDeadline = gate.recordUserActivity(at: initialDeadline - 1)
        XCTAssertEqual(renewedDeadline, initialDeadline + 59_999_999_999)
        XCTAssertFalse(gate.shouldClose(at: renewedDeadline! - 1))
        XCTAssertTrue(gate.shouldClose(at: renewedDeadline!))
    }

    func testIndicatorPriorityMakesSocialAndCognitiveStateLegible() {
        var inputs = SubconsciousIndicatorInputs(
            visualState: .none,
            interactionState: .idle
        )
        XCTAssertEqual(inputs.resolvedState, .exploring)
        inputs.visualState = .humanDetected
        XCTAssertEqual(inputs.resolvedState, .humanDetected)
        inputs.visualState = .eyeContact
        XCTAssertEqual(inputs.resolvedState, .contactReady)
        inputs.interactionState = .conversation
        XCTAssertEqual(inputs.resolvedState, .conversation)
        inputs.interactionState = .preparingReply
        XCTAssertEqual(inputs.resolvedState, .working)
        inputs.visualState = .none
        inputs.interactionState = .idle
        XCTAssertEqual(inputs.resolvedState, .exploring)
    }

    func testHumanPresenceIndicatorIsIndependentOfMotorOrConversationGates() {
        var inputs = SubconsciousIndicatorInputs()
        inputs.observeHumanVisualPresence()
        XCTAssertEqual(inputs.visualState, .humanDetected)
        XCTAssertEqual(inputs.interactionState, .idle)

        inputs.visualState = .eyeContact
        inputs.observeHumanVisualPresence()
        XCTAssertEqual(inputs.visualState, .eyeContact)
    }

    func testIndicatorSignalsResolveToFixedDeviceRenderings() {
        XCTAssertEqual(SubconsciousIndicatorState.contactReady.humanMeaning, "ready_speak_now")
        XCTAssertEqual(SubconsciousIndicatorState.conversation.humanMeaning, "conversation_active")
        XCTAssertEqual(SubconsciousIndicatorState.working.humanMeaning, "please_wait_preparing_reply")
        let blueSteady = SOMALEDDeviceRendering(stateID: 57, specialPatternEnabled: false)
        let blueBlink = SOMALEDDeviceRendering(stateID: 57, specialPatternEnabled: true)
        let yellowSteady = SOMALEDDeviceRendering(stateID: 16, specialPatternEnabled: false)
        XCTAssertEqual(SOMALEDColor.blue.firmwareStateID, blueSteady.stateID)
        XCTAssertEqual(SOMALEDColor.yellow.firmwareStateID, yellowSteady.stateID)
        XCTAssertTrue(blueBlink.specialPatternEnabled)
        XCTAssertFalse(blueSteady.specialPatternEnabled)
    }

    func testEyeContactIndicatorLeaseBridgesBriefGazeDropoutsOnly() {
        let start: UInt64 = 9_000_000_000
        var lease = EyeContactIndicatorLease(holdMilliseconds: 3_000)

        lease.observe(at: start)
        XCTAssertTrue(lease.isActive(at: start + 2_999_000_000))
        XCTAssertTrue(lease.isActive(at: start + 3_000_000_000))
        XCTAssertFalse(lease.isActive(at: start + 3_001_000_000))

        lease.observe(at: start + 4_000_000_000)
        lease.clear()
        XCTAssertFalse(lease.isActive(at: start + 4_001_000_000))

        lease.observe(sceneID: "face-a", at: start)
        XCTAssertTrue(lease.maintain(sceneID: "face-a", at: start + 10_000_000_000))
        XCTAssertTrue(lease.isActive(at: start + 12_999_000_000))
        XCTAssertFalse(lease.maintain(sceneID: "face-b", at: start + 13_000_000_000))
    }

    func testLiveVoiceLaunchGateDebouncesAndHasBoundedRetry() {
        var gate = LiveVoiceLaunchGate()
        let start: UInt64 = 10_000_000_000
        XCTAssertTrue(gate.beginLaunch(at: start))
        XCTAssertFalse(gate.beginLaunch(at: start + 1))
        gate.fail(at: start, retryMilliseconds: 5_000)
        XCTAssertFalse(gate.beginLaunch(at: start + 4_999_999_999))
        XCTAssertTrue(gate.beginLaunch(at: start + 5_000_000_000))
        gate.observeActive()
        XCTAssertEqual(gate.phase, .active)
        XCTAssertFalse(gate.beginLaunch(at: start + 6_000_000_000))
        gate.observeEnded()
        XCTAssertTrue(gate.beginLaunch(at: start + 6_000_000_000))
    }

    private func decision(
        model: EventImportanceModel,
        features: EventImportanceFeatures
    ) -> EventImportanceDecision {
        model.evaluate(
            EventImportanceInput(
                eventID: "test",
                monotonicNS: 1,
                evidenceIDs: ["evidence:test"],
                features: features
            )
        )
    }

    private func loadBootstrapCorpus() throws -> [LabelledEventImportanceExample] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = sourceRoot
            .appendingPathComponent("Sources/SOMAEventEval/Resources/bootstrap-v3.jsonl")
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(LabelledEventImportanceExample.self, from: Data($0.utf8)) }
    }
}
#endif
