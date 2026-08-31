import Foundation
import Testing
@testable import SOMACore

@Suite struct L1LiveConversationToolAdviceTests {
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
}
