import Foundation
import Testing
@testable import SOMACore

@Suite struct L1LiveConversationToolAdviceTests {
    @Test func explicitStatusReportUsesImmediateReadOnlyOverviewRoute() throws {
        let request = L1LiveToolAdviceRequest(
            threadID: "thread-status",
            latestUserTranscript: "상황 보고해. 상세 상태 보고하라니까.",
            availableTools: ["get_activity_overview", "get_robot_body_state"]
        )

        let advice = try #require(L1LiveEpistemicReflexRouter.route(request))
        #expect(advice.action == .recommendTool)
        #expect(advice.toolName == "get_activity_overview")
        #expect(advice.groundingQuote == "상태 보고")
    }

    @Test func explicitStatusReportRoutesSpecificPhysicalSubjectFirst() throws {
        let request = L1LiveToolAdviceRequest(
            threadID: "thread-gimbal-status",
            latestUserTranscript: "짐벌 상태 보고해.",
            availableTools: ["get_activity_overview", "get_robot_body_state"]
        )

        let advice = try #require(L1LiveEpistemicReflexRouter.route(request))
        #expect(advice.toolName == "get_robot_body_state")
    }

    @Test func explicitStatusReportRoutesDelegatedWorkSubjectFirst() throws {
        let request = L1LiveToolAdviceRequest(
            threadID: "thread-hermes-status",
            latestUserTranscript: "Report status on the delegated task.",
            availableTools: ["get_activity_overview", "list_hermes_tasks"]
        )

        let advice = try #require(L1LiveEpistemicReflexRouter.route(request))
        #expect(advice.toolName == "list_hermes_tasks")
    }

    @Test func casualStatusMentionStillUsesModelJudgment() {
        let request = L1LiveToolAdviceRequest(
            threadID: "thread-casual-status",
            latestUserTranscript: "The status report screen looks crowded.",
            availableTools: ["get_activity_overview"]
        )

        #expect(L1LiveEpistemicReflexRouter.route(request) == nil)
    }

    @Test func currentAppearanceQuestionUsesImmediateCameraRoute() throws {
        let request = L1LiveToolAdviceRequest(
            threadID: "thread-current-view",
            latestUserTranscript: "지금 내가 뭐 하고 있냐고?",
            availableTools: ["capture_view", "get_activity_overview"]
        )

        let advice = try #require(L1LiveEpistemicReflexRouter.route(request))
        #expect(advice.toolName == "capture_view")
        #expect(advice.groundingQuote == request.latestUserTranscript)
    }

    @Test func explicitCameraQuestionUsesImmediateCameraRouteAcrossLanguages() throws {
        for transcript in [
            "카메라에 지금 뭐 보여?", "지금 나 볼 수 있어", "Can you see me?",
            "你能看到我吗？", "カメラに何が映ってる？",
        ] {
            let request = L1LiveToolAdviceRequest(
                threadID: "thread-current-view",
                latestUserTranscript: transcript,
                availableTools: ["capture_view"]
            )
            #expect(try #require(L1LiveEpistemicReflexRouter.route(request)).toolName == "capture_view")
        }
    }

    @Test func robotStatusAndUnrelatedVisualLanguageDoNotCaptureCamera() throws {
        let status = L1LiveToolAdviceRequest(
            threadID: "thread-status",
            latestUserTranscript: "What are you doing?",
            availableTools: ["capture_view", "get_activity_overview"]
        )
        #expect(try #require(L1LiveEpistemicReflexRouter.route(status)).toolName == "get_activity_overview")

        let unrelated = L1LiveToolAdviceRequest(
            threadID: "thread-unrelated",
            latestUserTranscript: "Look, I think the plan is fine.",
            availableTools: ["capture_view"]
        )
        #expect(L1LiveEpistemicReflexRouter.route(unrelated) == nil)
    }

    @Test func currentCameraEvidenceClassifierIsPublicAndNarrow() {
        #expect(L1LiveEpistemicReflexRouter.requiresCurrentCameraEvidence(
            transcript: "나 지금 뭐 하고 있어?"
        ))
        #expect(L1LiveEpistemicReflexRouter.requiresCurrentCameraEvidence(
            transcript: "Can you see me?"
        ))
        #expect(!L1LiveEpistemicReflexRouter.requiresCurrentCameraEvidence(
            transcript: "Look, the plan is fine."
        ))
    }

    @Test func acceptsGroundedAvailableToolRecommendation() throws {
        let request = makeRequest(transcript: "지금 카메라에 뭐 보여?")
        let data = response(
            request,
            action: "recommend_tool",
            toolName: "capture_view",
            groundingQuote: "뭐 보여?"
        )

        let advice = try L1LiveToolAdviceResponseDecoder.decode(data, for: request)

        #expect(advice.action == .recommendTool)
        #expect(advice.toolName == "capture_view")
    }

    @Test func rejectsToolOutsideCurrentMCPContract() {
        let request = makeRequest(transcript: "파일을 지워줘")
        let data = response(
            request,
            action: "recommend_tool",
            toolName: "delete_everything",
            groundingQuote: "파일을 지워줘"
        )

        #expect(throws: L1LiveToolAdviceResponseError.self) {
            try L1LiveToolAdviceResponseDecoder.decode(data, for: request)
        }
    }

    @Test func rejectsRecommendationNotGroundedInLatestUserTurn() {
        let request = makeRequest(transcript: "오늘 기분 어때?")
        let data = response(
            request,
            action: "recommend_tool",
            toolName: "capture_view",
            groundingQuote: "카메라를 확인해"
        )

        #expect(throws: L1LiveToolAdviceResponseError.self) {
            try L1LiveToolAdviceResponseDecoder.decode(data, for: request)
        }
    }

    @Test func rejectsToolThatAlreadySucceededForTurn() {
        let request = L1LiveToolAdviceRequest(
            threadID: "thread-1",
            latestUserTranscript: "내 정보 기억나?",
            availableTools: ["get_person_context"],
            toolsAlreadyCalled: ["get_person_context"]
        )
        let data = response(
            request,
            action: "recommend_tool",
            toolName: "get_person_context",
            groundingQuote: "기억나?"
        )

        #expect(throws: L1LiveToolAdviceResponseError.self) {
            try L1LiveToolAdviceResponseDecoder.decode(data, for: request)
        }
    }

    @Test func acceptsNoAssistWithoutToolResidue() throws {
        let request = makeRequest(transcript: "안녕")
        let data = response(
            request,
            action: "no_assist",
            toolName: nil,
            groundingQuote: nil
        )

        let advice = try L1LiveToolAdviceResponseDecoder.decode(data, for: request)
        #expect(advice.action == .noAssist)
        #expect(advice.toolName == nil)
    }

    @Test func decodesOllamaNativeToolCallEnvelope() throws {
        let request = makeRequest(transcript: "Status report.")
        let data = nativeResponse(
            toolCalls: [[
                "function": [
                    "name": "get_activity_overview",
                    "arguments": ["grounding_quote": "Status report."],
                ],
            ]]
        )

        let advice = try L1LiveToolAdviceOllamaDecoder.decode(data, for: request)

        #expect(advice.action == .recommendTool)
        #expect(advice.toolName == "get_activity_overview")
        #expect(advice.groundingQuote == "Status report.")
    }

    @Test func nativeEnvelopeWithoutToolCallMeansNoAssist() throws {
        let request = makeRequest(transcript: "안녕")
        let advice = try L1LiveToolAdviceOllamaDecoder.decode(
            nativeResponse(toolCalls: []),
            for: request
        )

        #expect(advice.action == .noAssist)
        #expect(advice.toolName == nil)
    }

    @Test func rejectsMultipleNativeToolCalls() {
        let request = makeRequest(transcript: "상태랑 카메라를 확인해")
        let calls: [[String: Any]] = [
            ["function": ["name": "get_activity_overview", "arguments": ["grounding_quote": "상태"]]],
            ["function": ["name": "capture_view", "arguments": ["grounding_quote": "카메라"]]],
        ]

        #expect(throws: L1LiveToolAdviceResponseError.self) {
            try L1LiveToolAdviceOllamaDecoder.decode(nativeResponse(toolCalls: calls), for: request)
        }
    }

    @Test func rejectsUngroundedNativeToolCall() {
        let request = makeRequest(transcript: "오늘 기분 어때?")
        let data = nativeResponse(toolCalls: [[
            "function": [
                "name": "capture_view",
                "arguments": ["grounding_quote": "카메라 확인"],
            ],
        ]])

        #expect(throws: L1LiveToolAdviceResponseError.self) {
            try L1LiveToolAdviceOllamaDecoder.decode(data, for: request)
        }
    }

    @Test func rejectsNativeToolArgumentsOutsideTheAdvisoryContract() {
        let request = makeRequest(transcript: "Status report.")
        let data = nativeResponse(toolCalls: [[
            "function": [
                "name": "get_activity_overview",
                "arguments": [
                    "grounding_quote": "Status report.",
                    "invented_argument": true,
                ],
            ],
        ]])

        #expect(throws: L1LiveToolAdviceResponseError.self) {
            try L1LiveToolAdviceOllamaDecoder.decode(data, for: request)
        }
    }

    @Test func liveVoiceContextRetentionBoundsOnlyTheBackingConversationBody() {
        #expect(LiveVoiceContextRetentionPolicy.backingAutoCompactTokenLimit == 12_000)
        #expect(LiveVoiceContextRetentionPolicy.backingAutoCompactTokenLimitScope == "body_after_prefix")
        #expect(LiveVoiceContextRetentionPolicy.backingCompactionPrompt.contains("current goal"))
        #expect(LiveVoiceContextRetentionPolicy.backingCompactionPrompt.contains("persona"))
    }

    private func makeRequest(transcript: String) -> L1LiveToolAdviceRequest {
        L1LiveToolAdviceRequest(
            threadID: "thread-1",
            latestUserTranscript: transcript,
            availableTools: Array(L2CognitiveToolPolicy.knownToolNames)
        )
    }

    private func response(
        _ request: L1LiveToolAdviceRequest,
        action: String,
        toolName: String?,
        groundingQuote: String?
    ) -> Data {
        var object: [String: Any] = [
            "cycle_id": request.cycleID.uuidString.lowercased(),
            "thread_id": request.threadID,
            "turn_id": request.turnID.uuidString.lowercased(),
            "action": action,
            "confidence": 0.9,
            "rationale": "A tool result is needed before a grounded answer.",
        ]
        if let toolName { object["tool_name"] = toolName }
        if let groundingQuote { object["grounding_quote"] = groundingQuote }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func nativeResponse(toolCalls: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "model": "gemma4:31b-cloud",
            "message": [
                "role": "assistant",
                "content": "",
                "tool_calls": toolCalls,
            ],
            "done": true,
        ])
    }
}
