// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FlowClone",
    platforms: [
        .macOS(.v14),
        // Use a string so the manifest remains parseable by Swift 5.10's
        // PackageDescription API; the `.v26` constant was added in Swift 6.2.
        .iOS("26.0"),
    ],
    products: [
        // Consumed by Onyx Scribe Mobile (../Onyx Scribe Mobile) by relative path.
        .library(name: "FlowCloneCore", targets: ["FlowCloneCore"]),
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
