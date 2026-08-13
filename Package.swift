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
    ],
    targets: [
        .target(name: "SOMACore"),
        .target(
            name: "SOMAVADModel",
            resources: [.copy("Resources/SileroVAD256ms.mlmodelc")]
        ),
        .executableTarget(name: "SOMAProbe"),
        .executableTarget(
            name: "SOMASubconscious",
            dependencies: ["SOMACore", "SOMAVADModel"],
            resources: [
                .process("Resources/YOLOv3TinyFP16.mlmodel"),
                .copy("Resources/BlazeFaceShortRange.mlpackage")
            ]
        ),
        .executableTarget(name: "SOMACoreChecks", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMAVADEval", dependencies: ["SOMACore", "SOMAVADModel"]),
        .testTarget(name: "SOMACoreTests", dependencies: ["SOMACore", "SOMAVADModel"]),
    ]
)
