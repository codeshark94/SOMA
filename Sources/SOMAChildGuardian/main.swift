import Darwin
import Foundation

private enum GuardianError: LocalizedError {
    case invalidInvocation
    case childLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInvocation:
            "usage: soma-child-guardian --watch-stdin -- /absolute/child [arguments...]"
        case let .childLaunchFailed(reason):
            "child_launch_failed_\(reason)"
        }
    }
}

private func parseInvocation() throws -> (URL, [String]) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3,
          arguments[0] == "--watch-stdin",
          arguments[1] == "--",
          arguments[2].hasPrefix("/") else {
        throw GuardianError.invalidInvocation
    }
    return (URL(fileURLWithPath: arguments[2]), Array(arguments.dropFirst(3)))
}

private func waitForExit(of process: Process, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.025)
    }
}

private func terminate(_ process: Process) {
    guard process.isRunning else { return }
    let processGroup = -process.processIdentifier
    if Darwin.kill(processGroup, SIGTERM) != 0 {
        process.terminate()
    }
    waitForExit(of: process, timeout: 2)
    if process.isRunning {
        if Darwin.kill(processGroup, SIGKILL) != 0 {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        waitForExit(of: process, timeout: 1)
    }
}

do {
    let (executable, arguments) = try parseInvocation()
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw GuardianError.childLaunchFailed("executable_unavailable")
    }

    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    _ = Darwin.setpgid(child.processIdentifier, child.processIdentifier)

    let shutdown = DispatchSemaphore(value: 0)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let terminationSignals = [SIGTERM, SIGINT].map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { shutdown.signal() }
        source.resume()
        return source
    }
    _ = terminationSignals
    DispatchQueue.global(qos: .userInitiated).async {
        _ = try? FileHandle.standardInput.readToEnd()
        shutdown.signal()
    }

    while child.isRunning {
        if shutdown.wait(timeout: .now() + 0.1) == .success {
            terminate(child)
            Foundation.exit(EXIT_SUCCESS)
        }
    }
    Foundation.exit(child.terminationStatus == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data("soma-child-guardian: \(error.localizedDescription)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}
