// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fusion-event",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "fusion-event",
            path: "Sources/fusion-event",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-suppress-warnings"])
            ],
            linkerSettings: [
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
            ]
        ),
        .testTarget(
            name: "fusion-eventTests",
            dependencies: ["fusion-event"],
            path: "Tests/fusion-eventTests"
        )
    ]
)
