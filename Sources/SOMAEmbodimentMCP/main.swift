import Foundation
import SOMACore

private enum ServerFailure: Error, LocalizedError {
    case invalidArguments(String)
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message), let .protocolViolation(message): message
        }
    }
}

private struct ControlArguments: Codable {
    let requestId: String?
    let sourceLayer: CognitiveControlLayer
    let ownerId: String
    let priority: UInt8
    let leaseMs: UInt64
    let reason: String
    let evidenceIds: [String]?

    func request(operation: CognitiveEmbodimentOperation) -> CognitiveEmbodimentRequest {
        let requestID = requestId ?? UUID().uuidString.lowercased()
        let now = DispatchTime.now().uptimeNanoseconds
        return CognitiveEmbodimentRequest(
            requestID: requestID,
            layer: sourceLayer,
            reason: reason,
            evidenceIDs: evidenceIds ?? [],
            lease: EmbodimentLease(
                ownerID: ownerId,
                priority: priority,
                issuedAtNS: now,
                durationMilliseconds: leaseMs,
                cancellationToken: "mcp:\(requestID)"
            ),
            operation: operation
        )
    }
}

private struct RegisterArguments: Codable {
    let control: ControlArguments
    let registration: SemanticTargetArguments
}

private struct SemanticTargetArguments: Codable {
    let targetReference: String
    let sceneId: String?
    let label: String
    let aliases: [String]
    let visualQuery: String?
    let expectedKind: AttentionTargetKind?
    let initialSelectionLogPrior: Double

    var value: SemanticTargetRegistration {
        SemanticTargetRegistration(
            targetReference: targetReference,
            sceneID: sceneId,
            label: label,
            aliases: aliases,
            visualQuery: visualQuery,
            expectedKind: expectedKind,
            initialSelectionLogPrior: initialSelectionLogPrior
        )
    }
}

private struct RemoveArguments: Codable {
    let control: ControlArguments
    let targetReference: String
}

private struct AttentionArguments: Codable {
    let control: ControlArguments
    let policy: AttentionPolicyGoal
}

private struct TrackArguments: Codable {
    let control: ControlArguments
    let goal: TrackTargetGoal
}

private struct OrientArguments: Codable {
    let control: ControlArguments
    let goal: OrientGoal
}

private struct ExploreArguments: Codable {
    let control: ControlArguments
    let policy: ExplorationPolicyGoal
}

private struct CaptureArguments: Codable {
    let control: ControlArguments
    let goal: CaptureViewGoal
}

private struct ExpressionArguments: Codable {
    let control: ControlArguments
    let expression: SocialGimbalExpression
}

private struct ReleaseArguments: Codable {
    let control: ControlArguments
}

private struct ViewResultArguments: Codable {
    let requestId: String
}

private final class EmbodimentMCPServer {
    private let socketURL: URL
    private var initialized = false
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let supportedProtocolVersion = "2025-11-25"
    private let maximumLineBytes = 1_048_576

    init(socketURL: URL) {
        self.socketURL = socketURL
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard line.lengthOfBytes(using: .utf8) <= maximumLineBytes else {
                write(error: -32600, message: "request exceeds 1 MiB", id: NSNull())
                continue
            }
            do {
                let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
                guard let object = value as? [String: Any] else {
                    throw ServerFailure.protocolViolation("request must be a JSON object")
                }
                try handle(object)
            } catch {
                write(error: -32700, message: bounded(error.localizedDescription), id: NSNull())
            }
        }
    }

    private func handle(_ request: [String: Any]) throws {
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            throw ServerFailure.protocolViolation("invalid JSON-RPC request")
        }
        let id = request["id"] ?? NSNull()
        let isNotification = request["id"] == nil

        switch method {
        case "initialize":
            guard !isNotification else { return }
            initialized = true
            write(result: [
                "protocolVersion": supportedProtocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "soma-embodiment", "version": "0.3.0"],
                "instructions": "Leased semantic embodiment control routed to the local SOMA L0 arbiter. Inspect physical_actuation_enabled before assuming a goal can move hardware; L0 always retains route, stabilization, watchdog, and SDK authority."
            ], id: id)
        case "notifications/initialized", "notifications/cancelled":
            return
        case "ping":
            guard !isNotification else { return }
            write(result: [:], id: id)
        case "tools/list":
            guard initialized else {
                write(error: -32002, message: "server is not initialized", id: id)
                return
            }
            write(result: ["tools": toolDefinitions()], id: id)
        case "tools/call":
            guard initialized else {
                write(error: -32002, message: "server is not initialized", id: id)
                return
            }
            guard let parameters = request["params"] as? [String: Any],
                  let name = parameters["name"] as? String else {
                write(error: -32602, message: "tools/call requires a tool name", id: id)
                return
            }
            guard knownToolNames.contains(name) else {
                write(error: -32602, message: "unknown tool: \(name)", id: id)
                return
            }
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            do {
                let reply = try callTool(name: name, arguments: arguments)
                write(result: toolResult(reply), id: id)
            } catch ServerFailure.invalidArguments(let message) {
                write(result: toolFailure(message), id: id)
            } catch {
                write(result: toolFailure(error.localizedDescription), id: id)
            }
        default:
            if !isNotification { write(error: -32601, message: "method not found", id: id) }
        }
    }

    private func callTool(name: String, arguments: [String: Any]) throws -> EmbodimentIPCReply {
        if name == "get_embodiment_state"
            || name == "list_scene_entities"
            || name == "get_spatial_map" {
            guard arguments.isEmpty else { throw ServerFailure.invalidArguments("\(name) takes no arguments") }
            return try EmbodimentShadowSocketClient.send(.init(kind: .snapshot), socketURL: socketURL)
        }
        if name == "get_view_capture" {
            let value: ViewResultArguments = try decode(arguments)
            return try EmbodimentShadowSocketClient.send(
                .init(kind: .captureResult, requestID: value.requestId),
                socketURL: socketURL
            )
        }

        let request: CognitiveEmbodimentRequest
        switch name {
        case "register_semantic_target":
            let value: RegisterArguments = try decode(arguments)
            request = value.control.request(operation: .registerTarget(value.registration.value))
        case "remove_semantic_target":
            let value: RemoveArguments = try decode(arguments)
            request = value.control.request(operation: .removeTarget(value.targetReference))
        case "set_attention_policy":
            let value: AttentionArguments = try decode(arguments)
            request = value.control.request(operation: .setAttentionPolicy(value.policy))
        case "track_target":
            let value: TrackArguments = try decode(arguments)
            request = value.control.request(operation: .trackTarget(value.goal))
        case "orient_to":
            let value: OrientArguments = try decode(arguments)
            request = value.control.request(operation: .orient(value.goal))
        case "set_exploration_policy":
            let value: ExploreArguments = try decode(arguments)
            request = value.control.request(operation: .explore(value.policy))
        case "capture_view":
            let value: CaptureArguments = try decode(arguments)
            request = value.control.request(operation: .captureView(value.goal))
        case "express_gimbal":
            let value: ExpressionArguments = try decode(arguments)
            request = value.control.request(operation: .express(value.expression))
        case "release_embodiment":
            let value: ReleaseArguments = try decode(arguments)
            request = value.control.request(operation: .release)
        default:
            throw ServerFailure.invalidArguments("unknown tool: \(name)")
        }
        let initial = try EmbodimentShadowSocketClient.send(
            .init(kind: .submit, request: request),
            socketURL: socketURL
        )
        guard name == "capture_view", initial.ok else { return initial }
        guard initial.snapshot?.physicalActuationEnabled == true else {
            return EmbodimentIPCReply(
                ok: false,
                error: "capture_view_requires_physical_l0_adapter",
                decision: initial.decision,
                snapshot: initial.snapshot
            )
        }
        return try waitForViewCapture(request: request, initial: initial)
    }

    private func waitForViewCapture(
        request: CognitiveEmbodimentRequest,
        initial: EmbodimentIPCReply
    ) throws -> EmbodimentIPCReply {
        let maximumWaitNS: UInt64 = 15_000_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let boundedDeadline = min(request.lease.expiresAtNS, now + maximumWaitNS)
        var lastSnapshot = initial.snapshot
        while DispatchTime.now().uptimeNanoseconds < boundedDeadline {
            let reply = try EmbodimentShadowSocketClient.send(
                .init(kind: .captureResult, requestID: request.requestID),
                socketURL: socketURL
            )
            lastSnapshot = reply.snapshot ?? lastSnapshot
            if let resource = reply.viewResource {
                switch resource.state {
                case .ready:
                    return EmbodimentIPCReply(
                        ok: true,
                        decision: initial.decision,
                        snapshot: lastSnapshot,
                        viewResource: resource
                    )
                case .failed, .expired:
                    return EmbodimentIPCReply(
                        ok: false,
                        error: resource.failureReason ?? resource.state.rawValue,
                        decision: initial.decision,
                        snapshot: lastSnapshot,
                        viewResource: resource
                    )
                case .pendingAlignment, .awaitingFrame, .encoding:
                    break
                }
            } else if reply.error != "capture_result_unknown" {
                return reply
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return EmbodimentIPCReply(
            ok: false,
            error: "capture_wait_timeout; query get_view_capture with request_id=\(request.requestID)",
            decision: initial.decision,
            snapshot: lastSnapshot
        )
    }

    private func decode<T: Decodable>(_ arguments: [String: Any]) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ServerFailure.invalidArguments("invalid tool arguments: \(bounded(error.localizedDescription))")
        }
    }

    private func toolResult(_ reply: EmbodimentIPCReply) -> [String: Any] {
        guard let structured = try? jsonObject(reply),
              let textData = try? encoder.encode(reply),
              let text = String(data: textData, encoding: .utf8) else {
            return toolFailure("cannot encode L0 reply")
        }
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let resource = reply.viewResource,
           resource.state == .ready,
           let imagePath = resource.imagePath,
           let mimeType = resource.mimeType {
            content.append([
                "type": "resource_link",
                "name": "SOMA view \(resource.requestID)",
                "uri": URL(fileURLWithPath: imagePath).absoluteString,
                "mimeType": mimeType,
            ])
        }
        return [
            "content": content,
            "structuredContent": structured,
            "isError": !reply.ok,
        ]
    }

    private func toolFailure(_ message: String) -> [String: Any] {
        let safe = bounded(message)
        return [
            "content": [["type": "text", "text": safe]],
            "structuredContent": ["ok": false, "error": safe],
            "isError": true,
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private func write(result: [String: Any], id: Any) {
        writeJSON(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(error code: Int, message: String, id: Any) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": bounded(message)],
        ])
    }

    private func writeJSON(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private func bounded(_ message: String) -> String { String(message.prefix(240)) }

    private var knownToolNames: Set<String> {
        [
            "get_embodiment_state",
            "list_scene_entities",
            "get_spatial_map",
            "get_view_capture",
            "register_semantic_target",
            "remove_semantic_target",
            "set_attention_policy",
            "track_target",
            "orient_to",
            "set_exploration_policy",
            "capture_view",
            "express_gimbal",
            "release_embodiment",
        ]
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            tool("get_embodiment_state", "Read current L0 embodiment lease, target, and policy state.", objectSchema([:], required: []), readOnly: true),
            tool("list_scene_entities", "Read the bounded scalar projection of L0's persistent scene entities and semantic bindings.", objectSchema([:], required: []), readOnly: true),
            tool("get_spatial_map", "Read L0's bounded spherical coverage atlas, rolling panorama status, remembered scene bearings, and shared gimbal reachability envelope.", objectSchema([:], required: []), readOnly: true),
            tool("get_view_capture", "Read one short-lived capture result by request ID.", objectSchema([
                "request_id": stringSchema(maxLength: 96),
            ], required: ["request_id"]), readOnly: true),
            tool("register_semantic_target", "Register a stable semantic target label or visual query with L0.", objectSchema([
                "control": controlSchema(),
                "registration": registrationSchema(),
            ], required: ["control", "registration"])),
            tool("remove_semantic_target", "Remove a semantic target owned by the caller.", objectSchema([
                "control": controlSchema(),
                "target_reference": stringSchema(maxLength: 96),
            ], required: ["control", "target_reference"])),
            tool("set_attention_policy", "Set probabilistic target priors, commitment, novelty, habituation, and dwell policy.", objectSchema([
                "control": controlSchema(),
                "policy": attentionPolicySchema(),
            ], required: ["control", "policy"])),
            tool("track_target", "Lease tracking of one registered, scene-grounded semantic target through L0.", objectSchema([
                "control": controlSchema(),
                "goal": trackGoalSchema(),
            ], required: ["control", "goal"])),
            tool("orient_to", "Lease orientation toward a gimbal-home-relative spherical bearing through L0.", objectSchema([
                "control": controlSchema(),
                "goal": orientGoalSchema(),
            ], required: ["control", "goal"])),
            tool("set_exploration_policy", "Lease an exploration distribution over regions, bearings, tempo, dwell, novelty, and continuity.", objectSchema([
                "control": controlSchema(),
                "policy": explorationPolicySchema(),
            ], required: ["control", "policy"])),
            tool("capture_view", "Align a contextual view, capture the next settled frame, and return a short-lived local JPEG resource link.", objectSchema([
                "control": controlSchema(),
                "goal": captureGoalSchema(),
            ], required: ["control", "goal"])),
            tool("express_gimbal", "Lease a bounded semantic social gimbal expression through L0.", objectSchema([
                "control": controlSchema(),
                "expression": ["type": "string", "enum": SocialGimbalExpression.allCases.map(\.rawValue)],
            ], required: ["control", "expression"])),
            tool("release_embodiment", "Release the caller's motor lease, attention policy, and registered targets.", objectSchema([
                "control": controlSchema(),
            ], required: ["control"])),
        ]
    }

    private func tool(
        _ name: String,
        _ description: String,
        _ inputSchema: [String: Any],
        readOnly: Bool = false
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": false,
                "idempotentHint": readOnly || name == "release_embodiment",
                "openWorldHint": false,
            ],
        ]
    }

    private func controlSchema() -> [String: Any] {
        objectSchema([
            "request_id": stringSchema(maxLength: 96),
            "source_layer": ["type": "string", "enum": CognitiveControlLayer.allCases.map(\.rawValue)],
            "owner_id": stringSchema(maxLength: 96),
            "priority": ["type": "integer", "minimum": 0, "maximum": 100],
            "lease_ms": ["type": "integer", "minimum": 1, "maximum": 600_000],
            "reason": stringSchema(maxLength: 240),
            "evidence_ids": ["type": "array", "maxItems": 16, "items": stringSchema(maxLength: 128)],
        ], required: ["source_layer", "owner_id", "priority", "lease_ms", "reason"])
    }

    private func registrationSchema() -> [String: Any] {
        var schema = objectSchema([
            "target_reference": stringSchema(maxLength: 96),
            "scene_id": stringSchema(maxLength: 96),
            "label": stringSchema(maxLength: 96),
            "aliases": ["type": "array", "maxItems": 12, "items": stringSchema(maxLength: 96)],
            "visual_query": stringSchema(maxLength: 240),
            "expected_kind": ["type": "string", "enum": ["human", "object", "unknown"]],
            "initial_selection_log_prior": numberSchema(minimum: -12, maximum: 12),
        ], required: ["target_reference", "label", "aliases", "initial_selection_log_prior"])
        schema["anyOf"] = [
            ["required": ["scene_id"]],
            ["required": ["visual_query"]],
        ]
        return schema
    }

    private func attentionPolicySchema() -> [String: Any] {
        objectSchema([
            "targets": [
                "type": "array", "maxItems": 64,
                "items": objectSchema([
                    "target_reference": stringSchema(maxLength: 96),
                    "selection_log_prior": numberSchema(minimum: -12, maximum: 12),
                    "tracking_commitment": numberSchema(minimum: 0, maximum: 1),
                ], required: ["target_reference", "selection_log_prior", "tracking_commitment"]),
            ],
            "selection_temperature": numberSchema(minimum: 0.1, maximum: 5),
            "novelty_strength": numberSchema(minimum: 0, maximum: 1),
            "habituation_strength": numberSchema(minimum: 0, maximum: 1),
            "minimum_dwell_milliseconds": ["type": "integer", "minimum": 0, "maximum": 60_000],
            "maximum_dwell_milliseconds": ["type": "integer", "minimum": 0, "maximum": 60_000],
        ], required: ["targets", "selection_temperature", "novelty_strength", "habituation_strength", "minimum_dwell_milliseconds", "maximum_dwell_milliseconds"])
    }

    private func trackGoalSchema() -> [String: Any] {
        objectSchema([
            "target_reference": stringSchema(maxLength: 96),
            "framing": rectSchema(),
            "reacquire_if_occluded": ["type": "boolean"],
            "motion_style": motionStyleSchema(),
        ], required: ["target_reference", "reacquire_if_occluded", "motion_style"])
    }

    private func orientGoalSchema() -> [String: Any] {
        objectSchema([
            "bearing": bearingSchema(),
            "tolerance_degrees": numberSchema(minimum: 0.5, maximum: 30),
            "motion_style": motionStyleSchema(),
        ], required: ["bearing", "tolerance_degrees", "motion_style"])
    }

    private func explorationPolicySchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": ExplorationMode.allCases.map(\.rawValue)],
            "regions": [
                "type": "array", "maxItems": 32,
                "items": objectSchema([
                    "center": bearingSchema(),
                    "azimuth_radius_degrees": numberSchema(minimum: 1, maximum: 180),
                    "elevation_radius_degrees": numberSchema(minimum: 1, maximum: 90),
                    "preference": numberSchema(minimum: -1, maximum: 1),
                ], required: ["center", "azimuth_radius_degrees", "elevation_radius_degrees", "preference"]),
            ],
            "preferred_directions": [
                "type": "array", "maxItems": 32,
                "items": objectSchema([
                    "bearing": bearingSchema(),
                    "concentration": numberSchema(minimum: 0.1, maximum: 50),
                    "weight": ["type": "number", "exclusiveMinimum": 0],
                ], required: ["bearing", "concentration", "weight"]),
            ],
            "coverage_strength": numberSchema(minimum: 0, maximum: 1),
            "novelty_strength": numberSchema(minimum: 0, maximum: 1),
            "memory_gap_strength": numberSchema(minimum: 0, maximum: 1),
            "motion_continuity": numberSchema(minimum: 0, maximum: 1),
            "tempo": numberSchema(minimum: 0, maximum: 1),
            "dwell_milliseconds": ["type": "integer", "minimum": 0, "maximum": 60_000],
        ], required: ["mode", "regions", "preferred_directions", "coverage_strength", "novelty_strength", "memory_gap_strength", "motion_continuity", "tempo", "dwell_milliseconds"])
    }

    private func captureGoalSchema() -> [String: Any] {
        var schema = objectSchema([
            "target_reference": stringSchema(maxLength: 96),
            "bearing": bearingSchema(),
            "field_of_view_degrees": numberSchema(minimum: 5, maximum: 120),
        ], required: [])
        schema["anyOf"] = [
            ["required": ["target_reference"]],
            ["required": ["bearing"]],
        ]
        return schema
    }

    private func bearingSchema() -> [String: Any] {
        objectSchema([
            "azimuth_degrees": numberSchema(minimum: -180, maximum: 180),
            "elevation_degrees": numberSchema(minimum: -90, maximum: 90),
        ], required: ["azimuth_degrees", "elevation_degrees"])
    }

    private func rectSchema() -> [String: Any] {
        objectSchema([
            "x": numberSchema(minimum: 0, maximum: 1),
            "y": numberSchema(minimum: 0, maximum: 1),
            "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
            "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
        ], required: ["x", "y", "width", "height"])
    }

    private func motionStyleSchema() -> [String: Any] {
        ["type": "string", "enum": EmbodimentMotionStyle.allCases.map(\.rawValue)]
    }

    private func stringSchema(maxLength: Int) -> [String: Any] {
        ["type": "string", "minLength": 1, "maxLength": maxLength]
    }

    private func numberSchema(minimum: Double, maximum: Double) -> [String: Any] {
        ["type": "number", "minimum": minimum, "maximum": maximum]
    }

    private func objectSchema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
    }
}

private func parseSocketURL(_ arguments: [String]) throws -> URL {
    guard arguments.count == 2,
          arguments[0] == "--socket",
          arguments[1].hasPrefix("/") else {
        throw ServerFailure.invalidArguments("usage: soma-embodiment --socket /absolute/path.sock")
    }
    return URL(fileURLWithPath: arguments[1])
}

do {
    let socketURL = try parseSocketURL(Array(CommandLine.arguments.dropFirst()))
    EmbodimentMCPServer(socketURL: socketURL).run()
} catch {
    FileHandle.standardError.write(Data("soma-embodiment: \(error.localizedDescription)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}
