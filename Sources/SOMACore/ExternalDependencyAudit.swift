import Foundation

public enum ExternalDependencyCheckLevel: String, Codable, Sendable {
    case passed
    case warning
    case failed
}

public struct ExternalDependencyCheck: Equatable, Identifiable, Sendable {
    public let id: String
    public let level: ExternalDependencyCheckLevel
    public let detail: String

    public init(level: ExternalDependencyCheckLevel, detail: String) {
        self.level = level
        self.detail = detail
        id = "\(level.rawValue):\(detail)"
    }
}

public struct ExternalDependencyAudit: Equatable, Sendable {
    public let checks: [ExternalDependencyCheck]
    public let exitStatus: Int32

    public init(checks: [ExternalDependencyCheck], exitStatus: Int32) {
        self.checks = checks
        self.exitStatus = exitStatus
    }

    public var passedCount: Int { checks.count { $0.level == .passed } }
    public var warningCount: Int { checks.count { $0.level == .warning } }
    public var failedCount: Int { checks.count { $0.level == .failed } }
    public var isReady: Bool { failedCount == 0 }

    public static func parse(output: String, exitStatus: Int32) -> ExternalDependencyAudit {
        var seen = Set<String>()
        let checks = output.split(whereSeparator: \.isNewline).compactMap { raw -> ExternalDependencyCheck? in
            let line = String(raw)
            let level: ExternalDependencyCheckLevel
            let detail: Substring
            if line.hasPrefix("ok   ") {
                level = .passed
                detail = line.dropFirst(5)
            } else if line.hasPrefix("warn ") {
                level = .warning
                detail = line.dropFirst(5)
            } else if line.hasPrefix("fail ") {
                level = .failed
                detail = line.dropFirst(5)
            } else {
                return nil
            }
            let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, isExternalDependency(normalized) else { return nil }
            let check = ExternalDependencyCheck(level: level, detail: normalized)
            return seen.insert(check.id).inserted ? check : nil
        }
        return ExternalDependencyAudit(checks: checks, exitStatus: exitStatus)
    }

    private static func isExternalDependency(_ detail: String) -> Bool {
        let prefixes = [
            "Apple Silicon macOS",
            "macOS ",
            "Swift ",
            "Xcode command-line tools",
            "OpenCV ",
            "full-runtime macOS ",
            "CMake ",
            "persistent local code-signing identity ",
            "missing usable code-signing identity",
            "Ollama ",
            "Hermes Agent ",
            "configured Hermes Agent ",
            "optional Hermes Agent ",
            "Codex Live Voice ",
            "L2 Live Voice ",
            "L0.5 ",
            "optional ArcFace ",
            "installed ArcFace ",
            "connected OBSBOT ",
            "no connected OBSBOT ",
        ]
        return prefixes.contains { detail.hasPrefix($0) }
    }
}
