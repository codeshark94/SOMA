import Foundation

/// Owns a child through an inherited pipe rather than its PID alone.  If the
/// SOMA runtime exits unexpectedly, the kernel closes the pipe and the
/// guardian terminates the child before it can retain a stale local capability.
final class ParentBoundProcess: @unchecked Sendable {
    enum Error: LocalizedError {
        case guardianUnavailable

        var errorDescription: String? { "soma_child_guardian_unavailable" }
    }

    private let process = Process()
    private let livenessPipe = Pipe()
    private var started = false

    var isRunning: Bool { process.isRunning }

    init(
        guardianURL: URL,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: guardianURL.path) else {
            throw Error.guardianUnavailable
        }
        process.executableURL = guardianURL
        process.arguments = ["--watch-stdin", "--", executableURL.path] + arguments
        process.standardInput = livenessPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = environment
    }

    deinit { stop() }

    func run() throws {
        guard !started else { return }
        try process.run()
        started = true
    }

    func stop() {
        guard started else { return }
        try? livenessPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        started = false
    }

    static func installedGuardianURL() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SOMA_CHILD_GUARDIAN"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent("soma-child-guardian"),
            executableURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/soma-child-guardian"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
