// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BluepringMockingFramework",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "BluepringMockingFramework", targets: ["BlueprintMocking"]),
        .library(name: "BlueprintMockingTesting", targets: ["BlueprintMockingTesting"]),
        .library(name: "BlueprintMockingXCTest", targets: ["BlueprintMockingXCTest"])
    ],
    targets: [
        .target(name: "BlueprintMocking"),
        .target(name: "BlueprintMockingTesting", dependencies: ["BlueprintMocking"]),
        .target(name: "BlueprintMockingXCTest", dependencies: ["BlueprintMocking"]),
        .testTarget(name: "BlueprintMockingTests", dependencies: ["BlueprintMocking"])
    ],
    swiftLanguageModes: [.v6]
)
