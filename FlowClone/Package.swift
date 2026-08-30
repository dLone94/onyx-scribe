// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FlowClone",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        // Pure text-processing logic, framework-free (checkable without XCTest,
        // which CommandLineTools-only setups lack).
        .target(name: "FlowCloneCore"),
        .executableTarget(
            name: "FlowClone",
            dependencies: [
                "FlowCloneCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            resources: [
                .copy("Resources/Fonts"),
            ]
        ),
        // Plain assertion runner: `swift run FlowCloneChecks` (exit 1 on failure).
        .executableTarget(
            name: "FlowCloneChecks",
            dependencies: ["FlowCloneCore"]
        ),
    ]
)
