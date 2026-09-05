#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class HermesAgentTaskTests: XCTestCase {
    func testEveryAdvertisedMCPToolHasAnExplicitCognitivePolicy() {
        XCTAssertTrue(L2CognitiveToolPolicy.instruction.contains("standard single brief handoff acknowledgement"))
        XCTAssertTrue(L2CognitiveToolPolicy.instruction.contains("deliver one continuous grounded answer"))
        XCTAssertFalse(L2CognitiveToolPolicy.knownToolNames.isEmpty)
        for name in L2CognitiveToolPolicy.knownToolNames {
            XCTAssertNotNil(L2CognitiveToolPolicy.autonomy(for: name), name)
            XCTAssertNotNil(L2CognitiveToolPolicy.effect(for: name), name)
        }
    }

    func testEncryptedTaskStoreRoundTripsAndDoesNotExposeResult() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-hermes-task-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = CognitiveMemoryEncryptionKey.generate()
        let store = try HermesAgentTaskStore(directoryURL: directory, encryptionKey: key)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let task = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "Research task",
            objective: "Inspect one bounded question",
            workingDirectory: "/tmp",
            workClass: .sustainedResearch,
            acceptanceCriteria: "A cited report exists.",
            status: .completed,
            hermesStoredSessionID: "session-1",
            result: "private worker result",
            createdAt: timestamp,
            updatedAt: timestamp,
            completedAt: timestamp
        )

        try store.save([task])

        XCTAssertEqual(try store.load(), [task])
        let checkpoint = directory.appendingPathComponent(HermesAgentTaskStore.checkpointFilename)
        let raw = try String(contentsOf: checkpoint, encoding: .utf8)
        XCTAssertFalse(raw.contains("private worker result"))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: checkpoint.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testWorkerPromptPreservesCriteriaAfterMaximumLengthObjective() {
        let task = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "Long task",
            objective: String(repeating: "x", count: 24_000),
            workingDirectory: "/tmp",
            workClass: .artifactDelivery,
            acceptanceCriteria: "The requested artifact exists and opens successfully."
        )

        XCTAssertEqual(task.objective.count, 24_000)
        XCTAssertTrue(task.workerPrompt?.contains("Work class: artifact_delivery") == true)
        XCTAssertTrue(task.workerPrompt?.hasSuffix("The requested artifact exists and opens successfully.") == true)
    }

    func testLegacyTaskWithoutDelegationContractCannotProduceWorkerPrompt() {
        let task = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "Legacy task",
            objective: "Continue old work",
            workingDirectory: "/tmp"
        )

        XCTAssertNil(task.workerPrompt)
    }

    func testParticipantCannotUseExternalTaskAuthority() {
        let store = SOMASessionCapabilityStore(lifetimeSeconds: 60)
        let participant = store.issue(personEntityID: UUID(), authority: .participant)
        let administrator = store.issue(personEntityID: UUID(), authority: .administrator)

        if case let .failure(error) = store.authorize(
            token: participant,
            scope: .externalTaskDelegation
        ) {
            XCTAssertEqual(error, .externalTaskDelegationDenied)
        } else {
            XCTFail("participant external task authority must be denied")
        }
        if case .failure = store.authorize(
            token: administrator,
            scope: .externalTaskDelegation
        ) {
            XCTFail("administrator external task authority must be accepted")
        }
    }

    func testHermesToolsRequireExplicitDelegationButStatusReadsAreEpistemic() {
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "delegate_hermes_task"), .explicitRequest)
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.explicitRequest, for: "delegate_hermes_task"))
        XCTAssertFalse(L2CognitiveToolPolicy.permits(.autonomousGoal, for: "delegate_hermes_task"))
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "get_hermes_task"), .epistemic)
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.autonomousGoal, for: "get_hermes_task"))
        XCTAssertFalse(L2CognitiveToolPolicy.usesSemanticDeduplication(for: "get_hermes_task"))
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "resolve_hermes_report_offer"), .explicitRequest)
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.explicitRequest, for: "resolve_hermes_report_offer"))
        XCTAssertFalse(L2CognitiveToolPolicy.permits(.autonomousGoal, for: "resolve_hermes_report_offer"))

        XCTAssertFalse(L2CognitiveToolPolicy.requiresModelAuthoredIntent(for: "get_robot_body_state"))
        XCTAssertFalse(L2CognitiveToolPolicy.requiresModelAuthoredIntent(for: "get_activity_overview"))
        XCTAssertFalse(L2CognitiveToolPolicy.requiresModelAuthoredIntent(for: "capture_view"))
        XCTAssertTrue(L2CognitiveToolPolicy.requiresModelAuthoredIntent(for: "delegate_hermes_task"))
        XCTAssertFalse(L2CognitiveToolPolicy.usesSemanticDeduplication(for: "get_robot_body_state"))
        XCTAssertFalse(L2CognitiveToolPolicy.usesSemanticDeduplication(for: "capture_view"))
        XCTAssertTrue(L2CognitiveToolPolicy.usesSemanticDeduplication(for: "set_person_fact"))

        let gateway = L2CognitiveToolPolicy.gatewayIntent(for: "get_activity_overview")
        XCTAssertEqual(gateway?.authorizationBasis, .autonomousGoal)
        XCTAssertEqual(gateway?.evidenceIDs, [])
        XCTAssertFalse(gateway?.purpose.isEmpty ?? true)
        let captureGateway = L2CognitiveToolPolicy.gatewayIntent(for: "capture_view")
        XCTAssertEqual(captureGateway?.authorizationBasis, .autonomousGoal)
        XCTAssertEqual(captureGateway?.expectedInformationGain, 0.9)
        XCTAssertNil(L2CognitiveToolPolicy.gatewayIntent(for: "delegate_hermes_task"))
    }

    func testTaskRoutingSeparatesHostWorkFromRobotEmbodiment() {
        let enabled = L2TaskRoutingPolicy.instruction(hermesEnabled: true)
        XCTAssertTrue(enabled.contains("visible Mac UI"))
        XCTAssertTrue(enabled.contains("executed directly by backing Codex"))
        XCTAssertTrue(enabled.contains("delegate_hermes_task exactly once"))
        XCTAssertTrue(enabled.contains("Keep listening and converse normally"))
        XCTAssertTrue(enabled.contains("standard Live Voice handoff owns"))
        XCTAssertTrue(enabled.contains("One factual or web/API lookup"))
        XCTAssertTrue(enabled.contains("Fresh data or network access alone never requires Hermes"))
        XCTAssertTrue(enabled.contains("Do not read the task UUID aloud"))
        XCTAssertTrue(enabled.contains("Do not substitute screen pixels or get_robot_body_state"))
        XCTAssertTrue(enabled.contains("use get_activity_overview"))
        XCTAssertTrue(L2TaskRoutingPolicy.embodimentStateToolDescription.contains("not the host Mac"))
        XCTAssertTrue(L2TaskRoutingPolicy.hermesDelegationToolDescription.contains("declared work_class"))
        XCTAssertTrue(L2TaskRoutingPolicy.hermesDelegationToolDescription.contains("acceptance_criteria"))

        let disabled = L2TaskRoutingPolicy.instruction(hermesEnabled: false)
        XCTAssertTrue(disabled.contains("delegation is disabled"))
        XCTAssertFalse(disabled.contains("call delegate_hermes_task exactly once"))
    }

    func testHermesDelegationContractAdmitsOnlyDurableWorkClasses() {
        XCTAssertEqual(
            Set(HermesDelegatedWorkClass.allCases.map(\.rawValue)),
            Set([
                "artifact_delivery",
                "repository_change",
                "sustained_research",
                "service_management",
                "process_supervision",
            ])
        )
        XCTAssertNil(L2TaskRoutingPolicy.hermesDelegationValidationError(
            workClass: .sustainedResearch,
            objective: "Compare the literature and deliver a cited report.",
            acceptanceCriteria: "A reviewed report with primary-source citations exists.",
            workingDirectory: nil
        ))
        XCTAssertEqual(
            L2TaskRoutingPolicy.hermesDelegationValidationError(
                workClass: .repositoryChange,
                objective: "Implement and verify the requested change.",
                acceptanceCriteria: "The focused test and full build pass.",
                workingDirectory: nil
            ),
            "repository_change requires working_directory"
        )
        XCTAssertEqual(
            L2TaskRoutingPolicy.hermesDelegationValidationError(
                workClass: .artifactDelivery,
                objective: "Create the requested artifact.",
                acceptanceCriteria: "   ",
                workingDirectory: nil
            ),
            "delegate_hermes_task acceptance_criteria is required"
        )
    }

    func testActivityOverviewProjectionCannotDiscloseWorkerResult() throws {
        let task = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "Inspect runtime",
            objective: "Read sensitive host details",
            workingDirectory: "/tmp",
            status: .completed,
            result: "private worker result",
            completedAt: Date()
        )
        let activity = HermesAgentTaskActivity(task: task)
        let encoded = try String(decoding: JSONEncoder().encode(activity), as: UTF8.self)

        XCTAssertEqual(activity.id, task.id)
        XCTAssertEqual(activity.status, .completed)
        XCTAssertTrue(activity.awaitingReport)
        XCTAssertFalse(encoded.contains(task.objective))
        XCTAssertFalse(encoded.contains("private worker result"))
    }

    func testMCPDiagnosticsPreserveStructuredToolFailure() {
        let diagnostic = MCPToolCompletionDiagnostic.parse([
            "id": "item-1",
            "type": "mcpToolCall",
            "server": "soma_embodiment",
            "tool": "get_robot_body_state",
            "status": "completed",
            "result": [
                "structuredContent": [
                    "ok": false,
                    "error": "invalid tool arguments: unexpected field",
                ],
            ],
        ])

        XCTAssertEqual(diagnostic?.protocolStatus, "completed")
        XCTAssertEqual(diagnostic?.effectiveStatus, "failed")
        XCTAssertEqual(diagnostic?.error, "invalid tool arguments: unexpected field")
    }

    func testRootHermesSubmissionIsIdempotentAcrossObjectiveParaphrases() {
        let goalEpisodeID = UUID()
        let original = HermesAgentTask(
            goalEpisodeID: goalEpisodeID,
            title: "Inspect host state",
            objective: "Count the running SOMA processes.",
            workingDirectory: "/tmp"
        )
        let unrelated = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "Other request",
            objective: "Read another status.",
            workingDirectory: "/tmp"
        )
        let paraphrasedObjective = "Report how many SOMA processes are currently running."
        XCTAssertNotEqual(paraphrasedObjective, original.objective)

        XCTAssertEqual(
            HermesAgentTaskDeduplication.rootTask(
                for: goalEpisodeID,
                in: [original, unrelated]
            ),
            original
        )
    }

    func testCompletedHermesResultIsOfferedOnceAndDisclosedOnlyAfterAcceptance() throws {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let task = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "Inspect runtime",
            objective: "Inspect the current runtime.",
            workingDirectory: "/tmp",
            status: .completed,
            result: "Verified result",
            completedAt: completedAt
        )

        XCTAssertEqual(HermesAgentReportWorkflow.pendingOffers(in: [task]), [task])
        let offered = try HermesAgentReportWorkflow.markOffered(
            task,
            at: completedAt.addingTimeInterval(1)
        )
        XCTAssertTrue(HermesAgentReportWorkflow.pendingOffers(in: [offered]).isEmpty)
        XCTAssertThrowsError(
            try HermesAgentReportWorkflow.resolve(task, wantsReport: true)
        ) { error in
            XCTAssertEqual(error as? HermesAgentReportWorkflowError, .notOffered)
        }

        let accepted = try HermesAgentReportWorkflow.resolve(
            offered,
            wantsReport: true,
            at: completedAt.addingTimeInterval(2)
        )
        XCTAssertEqual(accepted.task.reportDecision, .accepted)
        XCTAssertEqual(accepted.result, "Verified result")
        XCTAssertNotNil(accepted.task.reportedAt)

        let declined = try HermesAgentReportWorkflow.resolve(
            offered,
            wantsReport: false,
            at: completedAt.addingTimeInterval(3)
        )
        XCTAssertEqual(declined.task.reportDecision, .declined)
        XCTAssertNil(declined.result)
    }

    func testHermesReportOfferUsesPreferredLanguage() {
        XCTAssertEqual(
            HermesReportOfferPrompt.question(languageTag: "ko-KR"),
            "맡겨 주신 작업이 끝났어요. 지금 결과를 보고드릴까요?"
        )
        XCTAssertTrue(HermesReportOfferPrompt.question(languageTag: "zh-CN").contains("结果"))
        XCTAssertTrue(HermesReportOfferPrompt.question(languageTag: "en-US").contains("result"))
    }

    func testHermesTaskRoundTripsThroughOwnerOnlyIPC() throws {
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-h-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(at: socket) }
        let token = UUID().uuidString.lowercased()
        let expected = HermesAgentTask(
            goalEpisodeID: UUID(),
            title: "IPC task",
            objective: "Return an IPC result",
            workingDirectory: "/tmp"
        )
        let server = EmbodimentShadowSocketServer(
            socketURL: socket,
            sessionAuthorizationProvider: { supplied, scope in
                guard supplied == token, scope == .externalTaskDelegation else {
                    return .failure(SOMASessionCapabilityError.invalid)
                }
                return .success(())
            },
            hermesAgentTaskProvider: { request in
                guard request.operation == .get, request.taskID == expected.id else {
                    return .failure(EmbodimentIPCError.malformedMessage)
                }
                return .success(.init(task: expected))
            }
        )
        try server.start()
        defer { server.stop() }

        let reply = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .hermesAgentTask,
                hermesAgentTask: .init(operation: .get, taskID: expected.id),
                sessionAuthorization: token
            ),
            socketURL: socket
        )

        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.hermesAgentTask?.task, expected)
    }
}
#endif
