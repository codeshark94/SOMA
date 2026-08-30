#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class HermesAgentTaskTests: XCTestCase {
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
