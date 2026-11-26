// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BluepringMockingFramework",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BluepringMockingFramework", targets: ["BlueprintMocking"]),
        .library(name: "BlueprintMockingTesting", targets: ["BlueprintMockingTesting"])
    ],
    targets: [
        .target(name: "BlueprintMocking"),
        .target(name: "BlueprintMockingTesting", dependencies: ["BlueprintMocking"]),
        .testTarget(name: "BlueprintMockingTests", dependencies: ["BlueprintMocking"])
    ],
    swiftLanguageModes: [.v6]
)
