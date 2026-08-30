import XCTest
@testable import SOMACore

final class HermesAgentRuntimeTests: XCTestCase {
    func testExplicitExecutableOverrideWins() {
        let executable = "/custom/hermes"
        let configuration = HermesAgentRuntimeConfiguration.discover(
            environment: [
                "SOMA_HERMES_BINARY": executable,
                "PATH": "/fallback/bin",
            ],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == executable }
        )

        XCTAssertEqual(configuration?.executablePath, executable)
        XCTAssertEqual(configuration?.profileName, "default")
    }

    func testInvalidExplicitOverrideDisablesDiscovery() {
        let configuration = HermesAgentRuntimeConfiguration.discover(
            environment: [
                "SOMA_HERMES_BINARY": "relative/hermes",
                "PATH": "/valid/bin",
            ],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/valid/bin/hermes" }
        )

        XCTAssertNil(configuration)
    }

    func testDefaultDiscoveryPrefersUserLocalInstallation() {
        let configuration = HermesAgentRuntimeConfiguration.discover(
            environment: ["PATH": "/opt/homebrew/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/Users/test/.local/bin/hermes" || $0 == "/opt/homebrew/bin/hermes" }
        )

        XCTAssertEqual(configuration?.executablePath, "/Users/test/.local/bin/hermes")
        XCTAssertEqual(configuration?.profileName, "default")
    }

    func testLoopbackWorkerAlwaysPinsThePrimaryComputerSupervisor() {
        let configuration = HermesAgentRuntimeConfiguration(executablePath: "/usr/local/bin/hermes")

        XCTAssertEqual(
            configuration.loopbackWorkerArguments,
            [
                "--profile", "default",
                "serve", "--host", "127.0.0.1", "--port", "0", "--skip-build",
            ]
        )
    }
}
