import Foundation

/// Resolves the local Hermes CLI used by the asynchronous agent worker.
/// SOMA does not modify global Hermes or Codex configuration.
public struct HermesAgentRuntimeConfiguration: Equatable, Sendable {
    public let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> HermesAgentRuntimeConfiguration? {
        if let override = environment["SOMA_HERMES_BINARY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return validated(path: override, isExecutable: isExecutable)
        }

        var candidates = [
            URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(".local/bin/hermes").path,
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
        for component in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(
                URL(fileURLWithPath: String(component), isDirectory: true)
                    .appendingPathComponent("hermes").path
            )
        }

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            if let configuration = validated(path: candidate, isExecutable: isExecutable) {
                return configuration
            }
        }
        return nil
    }

    private static func validated(
        path: String,
        isExecutable: (String) -> Bool
    ) -> HermesAgentRuntimeConfiguration? {
        guard path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              !path.contains("\n"),
              !path.contains("\0"),
              isExecutable(path) else {
            return nil
        }
        return HermesAgentRuntimeConfiguration(
            executablePath: URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }
}
