// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SOMA",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "soma-probe", targets: ["SOMAProbe"]),
        .executable(name: "soma-subconscious", targets: ["SOMASubconscious"]),
        .executable(name: "soma-core-check", targets: ["SOMACoreChecks"]),
    ],
    targets: [
        .target(name: "SOMACore"),
        .executableTarget(name: "SOMAProbe"),
        .executableTarget(
            name: "SOMASubconscious",
            dependencies: ["SOMACore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "SOMACoreChecks", dependencies: ["SOMACore"]),
        .testTarget(name: "SOMACoreTests", dependencies: ["SOMACore"]),
    ]
)
