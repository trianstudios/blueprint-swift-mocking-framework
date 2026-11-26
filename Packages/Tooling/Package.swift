// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueprintMockingTools",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "blueprint-mocking", targets: ["BlueprintMockingCLI"]),
        .plugin(name: "BlueprintMockingBuildPlugin", targets: ["BlueprintMockingBuildPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "600.0.1")
    ],
    targets: [
        .executableTarget(
            name: "BlueprintMockingCLI",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ]
        ),
        .plugin(
            name: "BlueprintMockingBuildPlugin",
            capability: .buildTool(),
            dependencies: ["BlueprintMockingCLI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
