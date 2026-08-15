// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SOMA",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "soma-probe", targets: ["SOMAProbe"]),
        .executable(name: "soma-subconscious", targets: ["SOMASubconscious"]),
        .executable(name: "soma-core-check", targets: ["SOMACoreChecks"]),
        .executable(name: "soma-vad-eval", targets: ["SOMAVADEval"]),
        .executable(name: "soma-event-eval", targets: ["SOMAEventEval"]),
        .executable(name: "soma-embodiment", targets: ["SOMAEmbodimentMCP"]),
        .executable(name: "soma-codex-bridge", targets: ["SOMACodexBridge"]),
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
                .unsafeFlags(["-I", "/opt/homebrew/opt/opencv/include/opencv5"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "/opt/homebrew/opt/opencv/lib"]),
                .linkedLibrary("opencv_core"),
                .linkedLibrary("opencv_imgproc"),
                .linkedLibrary("opencv_stitching"),
            ]
        ),
        .executableTarget(name: "SOMAProbe"),
        .executableTarget(
            name: "SOMASubconscious",
            dependencies: ["SOMACore", "SOMAVADModel", "SOMAOpenCV"],
            resources: [
                .process("Resources/YOLOv3TinyFP16.mlmodel"),
                .copy("Resources/BlazeFaceShortRange.mlpackage")
            ]
        ),
        .executableTarget(name: "SOMACoreChecks", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMAVADEval", dependencies: ["SOMACore", "SOMAVADModel"]),
        .executableTarget(
            name: "SOMAEventEval",
            dependencies: ["SOMACore"],
            resources: [.copy("Resources/bootstrap-v3.jsonl")]
        ),
        .executableTarget(name: "SOMAEmbodimentMCP", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMACodexBridge", dependencies: ["SOMACore"]),
        .testTarget(name: "SOMACoreTests", dependencies: ["SOMACore", "SOMAVADModel"]),
    ]
)
