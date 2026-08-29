import Foundation

public enum L2ToolAutonomy: String, Codable, CaseIterable, Sendable {
    case epistemic
    case goalBoundEmbodiment = "goal_bound_embodiment"
    case groundedMemoryWrite = "grounded_memory_write"
    case explicitConsent = "explicit_consent"
    case explicitRequest = "explicit_request"
}

public enum L2CognitiveAuthorizationBasis: String, Codable, CaseIterable, Sendable {
    case autonomousGoal = "autonomous_goal"
    case explicitStatement = "explicit_statement"
    case explicitConsent = "explicit_consent"
    case explicitRequest = "explicit_request"
}

public enum CognitiveActionEffect: String, Codable, CaseIterable, Sendable {
    case epistemic
    case reversibleEmbodiment = "reversible_embodiment"
    case durableMemory = "durable_memory"
    case identityManagement = "identity_management"
    case conversationControl = "conversation_control"
}

public enum CognitiveActionStatus: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
}

/// A model-authored explanation of why a tool call belongs to the current
/// cognitive goal. It contains no hidden capability or transcript material.
public struct L2CognitiveToolIntent: Codable, Equatable, Sendable {
    public let goalEpisodeID: UUID
    public let purpose: String
    public let expectedInformationGain: Double
    public let evidenceIDs: [String]
    public let authorizationBasis: L2CognitiveAuthorizationBasis

    public init(
        goalEpisodeID: UUID,
        purpose: String,
        expectedInformationGain: Double,
        evidenceIDs: [String] = [],
        authorizationBasis: L2CognitiveAuthorizationBasis
    ) {
        self.goalEpisodeID = goalEpisodeID
        self.purpose = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.expectedInformationGain = expectedInformationGain.isFinite
            ? min(max(expectedInformationGain, 0), 1)
            : 0
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
        self.authorizationBasis = authorizationBasis
    }
}

/// A privacy-bounded record of one completed cognitive tool action. The
/// result fingerprint permits idempotence without persisting raw tool output.
public struct CognitiveActionEpisode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let goalEpisodeID: UUID
    public let sourceLayer: CognitiveControlLayer
    public let toolName: String
    public let effect: CognitiveActionEffect
    public let purpose: String
    public let expectedInformationGain: Double
    public let evidenceIDs: [String]
    public let status: CognitiveActionStatus
    public let resultFingerprint: String
    public let requestFingerprint: String?
    public let resultSummary: String
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        goalEpisodeID: UUID,
        sourceLayer: CognitiveControlLayer,
        toolName: String,
        effect: CognitiveActionEffect,
        purpose: String,
        expectedInformationGain: Double,
        evidenceIDs: [String] = [],
        status: CognitiveActionStatus,
        resultFingerprint: String,
        requestFingerprint: String? = nil,
        resultSummary: String,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.goalEpisodeID = goalEpisodeID
        self.sourceLayer = sourceLayer
        self.toolName = String(toolName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
        self.effect = effect
        self.purpose = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.expectedInformationGain = expectedInformationGain.isFinite
            ? min(max(expectedInformationGain, 0), 1)
            : 0
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
        self.status = status
        self.resultFingerprint = String(resultFingerprint.lowercased().prefix(128))
        self.requestFingerprint = requestFingerprint.map { String($0.lowercased().prefix(128)) }
        self.resultSummary = String(resultSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.completedAt = completedAt
    }

    public func isSemanticallyEquivalent(to other: Self) -> Bool {
        guard goalEpisodeID == other.goalEpisodeID,
              toolName == other.toolName,
              effect == other.effect,
              status == other.status else {
            return false
        }
        if let requestFingerprint, !requestFingerprint.isEmpty,
           let otherFingerprint = other.requestFingerprint, !otherFingerprint.isEmpty {
            return requestFingerprint == otherFingerprint
                && Set(evidenceIDs) == Set(other.evidenceIDs)
        }
        return purpose.caseInsensitiveCompare(other.purpose) == .orderedSame
            && Set(evidenceIDs) == Set(other.evidenceIDs)
            && resultFingerprint == other.resultFingerprint
    }
}

/// A privacy-bounded semantic lookup performed before a cognitive tool call.
/// It carries no tool result and cannot grant embodiment authority.
public struct CognitiveActionQuery: Codable, Equatable, Hashable, Sendable {
    public let goalEpisodeID: UUID
    public let toolName: String
    public let requestFingerprint: String
    public let evidenceIDs: [String]

    public init(
        goalEpisodeID: UUID,
        toolName: String,
        requestFingerprint: String,
        evidenceIDs: [String] = []
    ) {
        self.goalEpisodeID = goalEpisodeID
        self.toolName = String(toolName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
        self.requestFingerprint = String(requestFingerprint.lowercased().prefix(128))
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
    }
}

/// One source of truth for how conversational cognition may use SOMA MCP.
/// Enforcement remains in the capability store and L0 arbiter; this contract
/// tells every L2 transport when initiative is cognitively appropriate.
public enum L2CognitiveToolPolicy {
    public static let instruction = """
    Cognitive tool initiative: privately maintain one current conversational goal. Before each response, decide whether a permitted SOMA MCP action would materially reduce an uncertainty that blocks a useful answer, ground a deictic or embodied reference, advance that goal, preserve an explicitly stated durable fact, or verify completion. When it would, call the narrowest suitable tool proactively and silently; do not wait for the participant to name the tool or issue a command, do not speak a provisional wait message, and use the returned result before responding. When no tool materially helps, answer directly without a ceremonial call.

    Autonomous read-only perception, memory lookup, and current-state inspection are epistemic actions. Reversible camera orientation, tracking, or reframing may also be initiated when it is necessary for the active conversational goal and remains subject to L0 authority. Durable memory writes require an explicit fact or preference supplied or confirmed by the participant. Identity enrollment requires explicit consent. Ending the conversation and external file, shell, network, service, or system changes still require the participant's explicit request and applicable authority.

    Every non-read-only SOMA MCP call, and every autonomous read, must include cognitive_intent with one stable goal_episode_id reused across calls serving the same conversational objective, a concise private purpose, expected_information_gain from 0 to 1, only supplied evidence_ids, and authorization_basis. Use autonomous_goal only for read-only perception/memory or reversible goal-bound orientation, tracking, reframing, and expression. Use explicit_statement for a fact or preference the participant just supplied, explicit_consent for identity enrollment, and explicit_request for conversation termination or device configuration the participant explicitly requested. Generate a new goal_episode_id when the conversational objective materially changes. Never expose these fields to the participant. Do not repeat a call when the same goal and semantic request already produced an equivalent result; treat tool failure as evidence and never claim an unverified result.
    """

    public static func autonomy(for toolName: String) -> L2ToolAutonomy? {
        switch toolName {
        case "get_embodiment_state", "list_scene_entities", "get_spatial_map",
             "get_view_capture", "list_present_people", "list_identity_registry",
             "get_person_context", "recall_episodes", "list_information_needs":
            .epistemic
        case "set_preferred_language", "clear_preferred_language", "set_contact_preference",
             "set_person_rapport", "set_person_fact", "remove_person_fact",
             "record_information_need_answer":
            .groundedMemoryWrite
        case "enroll_present_identity":
            .explicitConsent
        case "end_conversation":
            .explicitRequest
        case "register_semantic_target", "remove_semantic_target", "set_attention_policy",
             "track_target", "orient_to", "set_exploration_policy", "capture_view",
             "set_camera_optical_zoom", "set_device_sound_following", "express_gimbal",
             "release_embodiment":
            .goalBoundEmbodiment
        case "set_audio_capture_mode", "set_audio_input_gain", "set_camera_white_balance",
             "set_camera_exposure_lock", "set_camera_focus", "set_camera_absolute_exposure",
             "set_camera_face_priority", "set_camera_anti_flicker", "set_camera_image_tuning",
             "set_native_human_tracking_policy", "set_camera_field_of_view":
            .explicitRequest
        default:
            nil
        }
    }

    public static func effect(for toolName: String) -> CognitiveActionEffect? {
        switch toolName {
        case "get_embodiment_state", "list_scene_entities", "get_spatial_map",
             "get_view_capture", "list_present_people", "list_identity_registry",
             "get_person_context", "recall_episodes", "list_information_needs":
            .epistemic
        case "set_preferred_language", "clear_preferred_language", "set_contact_preference",
             "set_person_rapport", "set_person_fact", "remove_person_fact",
             "record_information_need_answer":
            .durableMemory
        case "enroll_present_identity":
            .identityManagement
        case "end_conversation":
            .conversationControl
        default:
            autonomy(for: toolName) == nil ? nil : .reversibleEmbodiment
        }
    }

    public static func permits(
        _ basis: L2CognitiveAuthorizationBasis,
        for toolName: String
    ) -> Bool {
        switch autonomy(for: toolName) {
        case .epistemic:
            true
        case .goalBoundEmbodiment:
            basis == .autonomousGoal || basis == .explicitRequest
        case .groundedMemoryWrite:
            basis == .explicitStatement || basis == .explicitRequest
        case .explicitConsent:
            basis == .explicitConsent
        case .explicitRequest:
            basis == .explicitRequest
        case nil:
            false
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
