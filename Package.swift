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
        .executableTarget(name: "SOMAProbe"),
        .executableTarget(
            name: "SOMASubconscious",
            dependencies: ["SOMACore"],
            resources: [
                .process("Resources/YOLOv3TinyFP16.mlmodel"),
                .copy("Resources/BlazeFaceShortRange.mlpackage")
            ]
        ),
        .executableTarget(name: "SOMACoreChecks", dependencies: ["SOMACore"]),
        .executableTarget(name: "SOMAVADEval", dependencies: ["SOMACore"]),
        .testTarget(name: "SOMACoreTests", dependencies: ["SOMACore"]),
    ]
)
