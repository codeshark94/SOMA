import Foundation

/// Layer (L0/L2/L3) and Ollama configuration that is managed as a plain
/// `.env` file so it can be sourced by the launch agent shell script before
/// the runtime binary starts. Keeping these as environment variables means the
/// running process can read them directly with no extra plumbing, and the
/// secret (Ollama API key) is held in an owner-only file rather than a JSON
/// settings blob.
///
/// Each field maps to a `KEY=VALUE` line. Values are written verbatim and read
/// back line-by-line, so hand-edits to the `.env` are respected.
public struct SOMAEnvSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    // MARK: Ollama — cloud access
    /// Ollama API key used by the hosted web_search / web_fetch endpoints.
    public var ollamaAPIKey: String
    /// Base HTTP host for the local Ollama server.
    public var ollamaHost: String
    /// The L1 conscious-stream model served by Ollama.
    public var l1Model: String

    // MARK: L0 — perception & attention
    /// Whether the gimbal may track a verified human face (native tracking).
    public var l0TrackingEnabled: Bool
    /// Whether the gimbal may autonomously explore when no verified target is
    /// present.
    public var l0ExploreEnabled: Bool
    /// Whether to time-limit a face fixation that never becomes engagement.
    /// 0 (default) keeps gazing indefinitely; a positive value tolerates
    /// non-response for that many seconds before releasing the face lock and
    /// resuming scanning. The judgment-based E2B release is unaffected.
    public var l0FaceFixationReleaseSeconds: Double

    // MARK: L1 — conscious stream (situation awareness cadence)
    /// How often (seconds) L1 re-runs its situation-awareness pass while a
    /// person is present.
    public var l1ActiveCadenceSeconds: Double
    /// How often (seconds) L1 re-runs while no person is present.
    public var l1IdleCadenceSeconds: Double
    /// Whether the L1 curiosity collector performs periodic web collection on
    /// the topics the model is curious about and feeds them back into openers.
    public var l1CuriosityCollectionEnabled: Bool
    /// How often (hours) the curiosity collector re-searches its topics.
    public var l1CollectionIntervalHours: Double
    /// How readily L1 opens a spoken conversation despite the person appearing
    /// busy/focused. 0 = conservative (stay quiet when busy), 1 = talkative
    /// (open even when the person looks focused on something).
    public var l1SpokenOpeningTendency: Double
    /// BCP-47 language tag L1 uses to address a person who has no stored
    /// preferred language. Defaults to "ko" (Korean).
    public var l1DefaultLanguage: String
    /// Minimum local-vision (E2B) wake score (0...1) for a wake proposal to
    /// reach L1. E2B is the low-latency on-device vision layer (L0).
    public var l0E2BWakeScore: Double
    /// Minimum local-vision (E2B) confidence (0...1) for a wake proposal to
    /// reach L1.
    public var l0E2BWakeConfidence: Double
    /// Minimum interval (ms) between local-vision (E2B) wake proposals for the
    /// same situation.
    public var l0E2BWakeIntervalMilliseconds: Double
    /// Whether the local-vision (E2B) layer is launched at all. E2B is a core
    /// dependency: it supplies the auxiliary semantic cues, low-social-presence
    /// judgment releases, object recognition, space transitions, and L1 wake
    /// proposals. Defaults to true.
    public var l05Enabled: Bool
    /// How long (ms) a fresh directed eye-contact observation remains valid for
    /// authorizing a spoken opening. Lower = stricter (requires very recent
    /// gaze); higher = more lenient. Defaults to 450.
    public var l0EyeContactFreshnessMilliseconds: Double
    /// Scales the pupil-centering thresholds that decide directed eye contact.
    /// 1.0 = default (0.68 X / 0.82 Y). Lower = stricter (pupil must be more
    /// centered); higher = more lenient. Defaults to 1.0.
    public var l0EyeContactPupilThreshold: Double
    /// Minimum confidence (0...1) for the on-device YOLO object detector to
    /// report an object. Higher = fewer false positives (e.g. phantom
    /// toothbrushes), lower = more recall. Defaults to 0.5.
    public var l0YoloConfidenceThreshold: Double
    /// How long (hours) raw short-term conversation transcripts are retained
    /// before L1 consolidation. Defaults to 24.
    public var memoryShortTermRetentionHours: Double

    // MARK: L2 — human interaction & conversation
    /// Whether L1 may initiate proactive spoken openings that hand off to the
    /// L2 live-voice conversation runtime.
    public var l2ProactiveOpeningsEnabled: Bool
    /// When true, L1 may proactively open a spoken conversation with a person
    /// it has not yet recognized (an unknown face), treating them as a
    /// pseudonymous participant. Defaults to false.
    public var l1OpenWithUnknownIdentity: Bool
    /// The Codex app-server sandbox level used for L2 live-voice sessions.
    /// One of "read-only", "workspace-write", or "danger-full-access".
    public var l2CodexSandbox: String
    /// When true, only the local administrator gets the configured Codex
    /// sandbox; every other participant is restricted to read-only.
    public var l2CodexAdminOnly: Bool

    public init(
        schemaVersion: Int = SOMAEnvSettings.currentSchemaVersion,
        ollamaAPIKey: String = "",
        ollamaHost: String = "http://127.0.0.1:11434",
        l1Model: String = "gemma4:31b-cloud",
        l0TrackingEnabled: Bool = true,
        l0ExploreEnabled: Bool = true,
        l0FaceFixationReleaseSeconds: Double = 0,
        l1ActiveCadenceSeconds: Double = 30,
        l1IdleCadenceSeconds: Double = 150,
        l1CuriosityCollectionEnabled: Bool = true,
        l1CollectionIntervalHours: Double = 24,
        l1SpokenOpeningTendency: Double = 0.5,
        l1DefaultLanguage: String = "ko",
        l0E2BWakeScore: Double = 0.65,
        l0E2BWakeConfidence: Double = 0.55,
        l0E2BWakeIntervalMilliseconds: Double = 5_000,
        l05Enabled: Bool = true,
        l0EyeContactFreshnessMilliseconds: Double = 450,
        l0EyeContactPupilThreshold: Double = 1.0,
        l0YoloConfidenceThreshold: Double = 0.5,
        memoryShortTermRetentionHours: Double = 24,
        l2ProactiveOpeningsEnabled: Bool = true,
        l1OpenWithUnknownIdentity: Bool = false,
        l2CodexSandbox: String = "danger-full-access",
        l2CodexAdminOnly: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.ollamaAPIKey = ollamaAPIKey
        self.ollamaHost = ollamaHost
        self.l1Model = l1Model
        self.l0TrackingEnabled = l0TrackingEnabled
        self.l0ExploreEnabled = l0ExploreEnabled
        self.l0FaceFixationReleaseSeconds = max(l0FaceFixationReleaseSeconds, 0)
        self.l1ActiveCadenceSeconds = l1ActiveCadenceSeconds
        self.l1IdleCadenceSeconds = l1IdleCadenceSeconds
        self.l1CuriosityCollectionEnabled = l1CuriosityCollectionEnabled
        self.l1CollectionIntervalHours = l1CollectionIntervalHours
        self.l1SpokenOpeningTendency = min(max(l1SpokenOpeningTendency, 0), 1)
        self.l1DefaultLanguage = l1DefaultLanguage
        self.l0E2BWakeScore = min(max(l0E2BWakeScore, 0), 1)
        self.l0E2BWakeConfidence = min(max(l0E2BWakeConfidence, 0), 1)
        self.l0E2BWakeIntervalMilliseconds = max(l0E2BWakeIntervalMilliseconds, 1_000)
        self.l05Enabled = l05Enabled
        self.l0EyeContactFreshnessMilliseconds = min(max(l0EyeContactFreshnessMilliseconds, 100), 2_000)
        self.l0EyeContactPupilThreshold = min(max(l0EyeContactPupilThreshold, 0.1), 2.0)
        self.l0YoloConfidenceThreshold = min(max(l0YoloConfidenceThreshold, 0.1), 0.95)
        self.memoryShortTermRetentionHours = min(max(memoryShortTermRetentionHours, 1), 24)
        self.l2ProactiveOpeningsEnabled = l2ProactiveOpeningsEnabled
        self.l1OpenWithUnknownIdentity = l1OpenWithUnknownIdentity
        self.l2CodexSandbox = ["read-only", "workspace-write", "danger-full-access"].contains(l2CodexSandbox)
            ? l2CodexSandbox
            : "danger-full-access"
        self.l2CodexAdminOnly = l2CodexAdminOnly
    }

    /// Lines written to the `.env` file. Keys that have no value (empty secret)
    /// are still written as `KEY=` so the file stays self-documenting.
    func lines() -> [String] {
        [
            "# SOMA layer (L0/L1/L2) and Ollama configuration.",
            "# Managed by the SOMA Control Center. Restart SOMA to apply changes.",
            "OLLAMA_API_KEY=\(ollamaAPIKey)",
            "OLLAMA_HOST=\(ollamaHost)",
            "SOMA_L1_MODEL=\(l1Model)",
            "SOMA_L0_TRACKING_ENABLED=\(l0TrackingEnabled ? "true" : "false")",
            "SOMA_L0_EXPLORE_ENABLED=\(l0ExploreEnabled ? "true" : "false")",
            "SOMA_L0_FIXATION_RELEASE_SECONDS=\(String(format: "%g", l0FaceFixationReleaseSeconds))",
            "SOMA_L1_ACTIVE_CADENCE_SECONDS=\(String(format: "%g", l1ActiveCadenceSeconds))",
            "SOMA_L1_IDLE_CADENCE_SECONDS=\(String(format: "%g", l1IdleCadenceSeconds))",
            "SOMA_L1_CURIOSITY_ENABLED=\(l1CuriosityCollectionEnabled ? "true" : "false")",
            "SOMA_L1_CURIOSITY_INTERVAL_HOURS=\(String(format: "%g", l1CollectionIntervalHours))",
            "SOMA_L1_SPOKEN_OPENING_TENDENCY=\(String(format: "%g", l1SpokenOpeningTendency))",
            "SOMA_L1_DEFAULT_LANGUAGE=\(l1DefaultLanguage)",
            "SOMA_L0_E2B_WAKE_SCORE=\(String(format: "%g", l0E2BWakeScore))",
            "SOMA_L0_E2B_WAKE_CONFIDENCE=\(String(format: "%g", l0E2BWakeConfidence))",
            "SOMA_L0_E2B_WAKE_INTERVAL_MS=\(String(format: "%g", l0E2BWakeIntervalMilliseconds))",
            "SOMA_ENABLE_L05_VLM=\(l05Enabled ? "1" : "0")",
            "SOMA_L0_EYE_CONTACT_FRESHNESS_MS=\(String(format: "%g", l0EyeContactFreshnessMilliseconds))",
            "SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD=\(String(format: "%g", l0EyeContactPupilThreshold))",
            "SOMA_YOLO_CONFIDENCE_THRESHOLD=\(String(format: "%g", l0YoloConfidenceThreshold))",
            "SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS=\(String(format: "%g", memoryShortTermRetentionHours))",
            "SOMA_L2_PROACTIVE_OPENINGS=\(l2ProactiveOpeningsEnabled ? "true" : "false")",
            "SOMA_L1_OPEN_WITH_UNKNOWN=\(l1OpenWithUnknownIdentity ? "true" : "false")",
            "SOMA_L2_CODEX_SANDBOX=\(l2CodexSandbox)",
            "SOMA_L2_CODEX_ADMIN_ONLY=\(l2CodexAdminOnly ? "true" : "false")",
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case ollamaAPIKey
        case ollamaHost
        case l1Model
        case l0TrackingEnabled
        case l0ExploreEnabled
        case l0FaceFixationReleaseSeconds
        case l1ActiveCadenceSeconds
        case l1IdleCadenceSeconds
        case l1CuriosityCollectionEnabled
        case l1CollectionIntervalHours
        case l1SpokenOpeningTendency
        case l1DefaultLanguage
        case l0E2BWakeScore
        case l0E2BWakeConfidence
        case l0E2BWakeIntervalMilliseconds
        case l05Enabled
        case l0EyeContactFreshnessMilliseconds
        case l0EyeContactPupilThreshold
        case l0YoloConfidenceThreshold
        case memoryShortTermRetentionHours
        case l2ProactiveOpeningsEnabled
        case l1OpenWithUnknownIdentity
        case l2CodexSandbox
        case l2CodexAdminOnly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        ollamaAPIKey = try values.decodeIfPresent(String.self, forKey: .ollamaAPIKey) ?? ""
        ollamaHost = try values.decodeIfPresent(String.self, forKey: .ollamaHost) ?? "http://127.0.0.1:11434"
        l1Model = try values.decodeIfPresent(String.self, forKey: .l1Model) ?? "gemma4:31b-cloud"
        l0TrackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .l0TrackingEnabled) ?? true
        l0ExploreEnabled = try values.decodeIfPresent(Bool.self, forKey: .l0ExploreEnabled) ?? true
        l0FaceFixationReleaseSeconds = max(try values.decodeIfPresent(Double.self, forKey: .l0FaceFixationReleaseSeconds) ?? 0, 0)
        l1ActiveCadenceSeconds = try values.decodeIfPresent(Double.self, forKey: .l1ActiveCadenceSeconds) ?? 30
        l1IdleCadenceSeconds = try values.decodeIfPresent(Double.self, forKey: .l1IdleCadenceSeconds) ?? 150
        l1CuriosityCollectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .l1CuriosityCollectionEnabled) ?? true
        l1CollectionIntervalHours = try values.decodeIfPresent(Double.self, forKey: .l1CollectionIntervalHours) ?? 24
        l1SpokenOpeningTendency = min(max(try values.decodeIfPresent(Double.self, forKey: .l1SpokenOpeningTendency) ?? 0.5, 0), 1)
        l1DefaultLanguage = try values.decodeIfPresent(String.self, forKey: .l1DefaultLanguage) ?? "ko"
        l0E2BWakeScore = min(max(try values.decodeIfPresent(Double.self, forKey: .l0E2BWakeScore) ?? 0.65, 0), 1)
        l0E2BWakeConfidence = min(max(try values.decodeIfPresent(Double.self, forKey: .l0E2BWakeConfidence) ?? 0.55, 0), 1)
        l0E2BWakeIntervalMilliseconds = max(try values.decodeIfPresent(Double.self, forKey: .l0E2BWakeIntervalMilliseconds) ?? 5_000, 1_000)
        l05Enabled = try values.decodeIfPresent(Bool.self, forKey: .l05Enabled) ?? true
        l0EyeContactFreshnessMilliseconds = min(max(try values.decodeIfPresent(Double.self, forKey: .l0EyeContactFreshnessMilliseconds) ?? 450, 100), 2_000)
        l0EyeContactPupilThreshold = min(max(try values.decodeIfPresent(Double.self, forKey: .l0EyeContactPupilThreshold) ?? 1.0, 0.1), 2.0)
        l0YoloConfidenceThreshold = min(max(try values.decodeIfPresent(Double.self, forKey: .l0YoloConfidenceThreshold) ?? 0.5, 0.1), 0.95)
        memoryShortTermRetentionHours = min(max(try values.decodeIfPresent(Double.self, forKey: .memoryShortTermRetentionHours) ?? 24, 1), 24)
        l2ProactiveOpeningsEnabled = try values.decodeIfPresent(Bool.self, forKey: .l2ProactiveOpeningsEnabled) ?? true
        l1OpenWithUnknownIdentity = try values.decodeIfPresent(Bool.self, forKey: .l1OpenWithUnknownIdentity) ?? false
        let sandbox = try values.decodeIfPresent(String.self, forKey: .l2CodexSandbox) ?? "danger-full-access"
        l2CodexSandbox = ["read-only", "workspace-write", "danger-full-access"].contains(sandbox) ? sandbox : "danger-full-access"
        l2CodexAdminOnly = try values.decodeIfPresent(Bool.self, forKey: .l2CodexAdminOnly) ?? false
    }
}

public enum SOMAEnvStoreError: LocalizedError, Equatable, Sendable {
    case corruptEnv
    case insecurePermissions

    public var errorDescription: String? {
        switch self {
        case .corruptEnv:
            "SOMA .env could not be read"
        case .insecurePermissions:
            "SOMA .env permissions must be owner-only"
        }
    }
}

/// Reads and writes the SOMA layer configuration as a `.env` file with
/// owner-only permissions. Unknown keys are preserved on write? — no, this
/// store owns the file and rewrites it from `SOMAEnvSettings`.
public struct SOMAEnvStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultURL()) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/.env")
    }

    public func load() throws -> SOMAEnvSettings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .init() }
        try requireOwnerOnlyPermissions()
        let raw: String
        do {
            raw = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw SOMAEnvStoreError.corruptEnv
        }
        var values: [String: String] = [:]
        for rawLine in raw.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equalIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            // Strip surrounding quotes if present.
            var clean = value
            if clean.count >= 2, clean.first == "\"", clean.last == "\"" {
                clean = String(clean.dropFirst().dropLast())
            }
            values[key] = clean
        }
        return SOMAEnvSettings(
            ollamaAPIKey: values["OLLAMA_API_KEY"] ?? "",
            ollamaHost: values["OLLAMA_HOST"] ?? "http://127.0.0.1:11434",
            l1Model: values["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud",
            l0TrackingEnabled: boolValue(values["SOMA_L0_TRACKING_ENABLED"], default: true),
            l0ExploreEnabled: boolValue(values["SOMA_L0_EXPLORE_ENABLED"], default: true),
            l0FaceFixationReleaseSeconds: doubleValue(values["SOMA_L0_FIXATION_RELEASE_SECONDS"], default: 0),
            l1ActiveCadenceSeconds: doubleValue(values["SOMA_L1_ACTIVE_CADENCE_SECONDS"], default: 30),
            l1IdleCadenceSeconds: doubleValue(values["SOMA_L1_IDLE_CADENCE_SECONDS"], default: 150),
            l1CuriosityCollectionEnabled: boolValue(values["SOMA_L1_CURIOSITY_ENABLED"], default: true),
            l1CollectionIntervalHours: doubleValue(values["SOMA_L1_CURIOSITY_INTERVAL_HOURS"], default: 24),
            l1SpokenOpeningTendency: doubleValue(values["SOMA_L1_SPOKEN_OPENING_TENDENCY"], default: 0.5),
            l1DefaultLanguage: values["SOMA_L1_DEFAULT_LANGUAGE"] ?? "ko",
            l0E2BWakeScore: doubleValue(values["SOMA_L0_E2B_WAKE_SCORE"], default: 0.65),
            l0E2BWakeConfidence: doubleValue(values["SOMA_L0_E2B_WAKE_CONFIDENCE"], default: 0.55),
            l0E2BWakeIntervalMilliseconds: doubleValue(values["SOMA_L0_E2B_WAKE_INTERVAL_MS"], default: 5_000),
            l05Enabled: boolValue(values["SOMA_ENABLE_L05_VLM"], default: true),
            l0EyeContactFreshnessMilliseconds: doubleValue(values["SOMA_L0_EYE_CONTACT_FRESHNESS_MS"], default: 450),
            l0EyeContactPupilThreshold: doubleValue(values["SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD"], default: 1.0),
            l0YoloConfidenceThreshold: doubleValue(values["SOMA_YOLO_CONFIDENCE_THRESHOLD"], default: 0.5),
            memoryShortTermRetentionHours: doubleValue(values["SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS"], default: 24),
            l2ProactiveOpeningsEnabled: boolValue(values["SOMA_L2_PROACTIVE_OPENINGS"], default: true),
            l1OpenWithUnknownIdentity: boolValue(values["SOMA_L1_OPEN_WITH_UNKNOWN"], default: false),
            l2CodexSandbox: values["SOMA_L2_CODEX_SANDBOX"] ?? "danger-full-access",
            l2CodexAdminOnly: boolValue(values["SOMA_L2_CODEX_ADMIN_ONLY"], default: false)
        )
    }

    public func save(_ settings: SOMAEnvSettings) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let content = settings.lines().joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func requireOwnerOnlyPermissions() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw SOMAEnvStoreError.insecurePermissions
        }
    }

    private func boolValue(_ raw: String?, default defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return defaultValue
        }
    }

    private func doubleValue(_ raw: String?, default defaultValue: Double) -> Double {
        guard let raw, let value = Double(raw), value > 0 else { return defaultValue }
        return value
    }
}
