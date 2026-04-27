// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "pdff",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "pdff", targets: ["Pdff"]),
        .library(name: "PdffCore", targets: ["PdffCore"])
    ],
    targets: [
        .target(
            name: "PdffCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "Pdff",
            dependencies: ["PdffCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PdffCoreTests",
            dependencies: ["PdffCore"]
        )
    ]
)
