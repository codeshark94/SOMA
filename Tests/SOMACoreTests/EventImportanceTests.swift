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
