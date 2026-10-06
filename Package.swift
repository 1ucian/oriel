// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesCapture",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HermesCaptureCore", targets: ["HermesCaptureCore"]),
        .library(name: "HermesCaptureProtocol", targets: ["HermesCaptureProtocol"]),
    ],
    targets: [
        .target(name: "HermesCaptureCore"),
        .target(name: "HermesCaptureProtocol"),
        .testTarget(
            name: "HermesCaptureCoreTests",
            dependencies: ["HermesCaptureCore"]
        ),
        .testTarget(
            name: "HermesCaptureProtocolTests",
            dependencies: ["HermesCaptureProtocol"]
        ),
    ]
)
