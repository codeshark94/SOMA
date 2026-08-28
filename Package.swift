// swift-tools-version: 6.0

import PackageDescription
import Foundation

let opencvPrefix: String = {
    if let configured = ProcessInfo.processInfo.environment["SOMA_OPENCV_PREFIX"],
       !configured.isEmpty {
        return URL(fileURLWithPath: configured).standardizedFileURL.path
    }
    for candidate in ["/opt/homebrew/opt/opencv", "/usr/local/opt/opencv"]
    where FileManager.default.fileExists(atPath: candidate) {
        return candidate
    }
    return "/opt/homebrew/opt/opencv"
}()

let package = Package(
    name: "SOMA",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "soma-probe", targets: ["SOMAProbe"]),
        .executable(name: "soma-subconscious", targets: ["SOMASubconscious"]),
        .executable(name: "soma-core-check", targets: ["SOMACoreChecks"]),
        .executable(name: "soma-memory-recover", targets: ["SOMAMemoryRecovery"]),
        .executable(name: "soma-vad-eval", targets: ["SOMAVADEval"]),
        .executable(name: "soma-event-eval", targets: ["SOMAEventEval"]),
        .executable(name: "soma-embodiment", targets: ["SOMAEmbodimentMCP"]),
        .executable(name: "soma-codex-bridge", targets: ["SOMACodexBridge"]),
        .executable(name: "soma-live-voice", targets: ["SOMALiveVoice"]),
        .executable(name: "soma-menu-bar", targets: ["SOMAMenuBar"]),
        .executable(name: "soma-child-guardian", targets: ["SOMAChildGuardian"]),
    ],
    targets: [
        .target(name: "SOMACore"),
        .target(
            name: "SOMAVADModel",
            resources: [.copy("Resources/SileroVAD256ms.mlmodelc")]
        ),
        .target(
            name: "SOMAOpenCV",
            path: "Sources/SOMAOpenCV",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I", "\(opencvPrefix)/include/opencv5"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "\(opencvPrefix)/lib"]),
                .linkedLibrary("opencv_core"),
                .linkedLibrary("opencv_features"),
                .linkedLibrary("opencv_imgcodecs"),
                .linkedLibrary("opencv_imgproc"),
                .linkedLibrary("opencv_video"),
            ]
        ),
        .executableTarget(name: "SOMAProbe"),
        .executableTarget(
            name: "SOMASubconscious",
            dependencies: ["SOMACore", "SOMAVADModel", "SOMAOpenCV"],
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/YOLO11n.mlpackage"),
                .copy("Resources/BlazeFaceShortRange.mlpackage")
            ],
            linkerSettings: [
                .linkedFramework("Speech"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SOMASubconscious/Info.plist",
                ]),
            ]
        ),
        .executableTarget(name: "SOMACoreChecks", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMAMemoryRecovery", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMAVADEval", dependencies: ["SOMACore", "SOMAVADModel"]),
        .executableTarget(
            name: "SOMAEventEval",
            dependencies: ["SOMACore"],
            resources: [.copy("Resources/bootstrap-v3.jsonl")]
        ),
        .executableTarget(name: "SOMAEmbodimentMCP", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMACodexBridge", dependencies: ["SOMACore"]),
        .executableTarget(
            name: "SOMALiveVoice",
            dependencies: ["SOMACore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SOMALiveVoice/Info.plist",
                ]),
            ]
        ),
        .executableTarget(name: "SOMAMenuBar", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMAChildGuardian"),
        .testTarget(name: "SOMACoreTests", dependencies: ["SOMACore", "SOMAVADModel"]),
    ]
)
