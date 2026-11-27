// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueprintMockingTools",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "blueprint-mocking", targets: ["BlueprintMockingCLI"]),
        .plugin(name: "BlueprintMockingBuildPlugin", targets: ["BlueprintMockingBuildPlugin"]),
        .plugin(name: "BlueprintMockingReadCommand", targets: ["BlueprintMockingReadCommand"]),
        .plugin(name: "BlueprintMockingGenerateCommand", targets: ["BlueprintMockingGenerateCommand"])
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
        ),
        .plugin(
            name: "BlueprintMockingReadCommand",
            capability: .command(
                intent: .custom(verb: "blueprint-mocking-read", description: "Inspect or verify Blueprint mocks"),
                permissions: []
            ),
            dependencies: ["BlueprintMockingCLI"]
        ),
        .plugin(
            name: "BlueprintMockingGenerateCommand",
            capability: .command(
                intent: .custom(verb: "blueprint-mocking-generate", description: "Generate reviewable Blueprint mocks"),
                permissions: [.writeToPackageDirectory(reason: "Create a new directory with the requested generated mocks.")]
            ),
            dependencies: ["BlueprintMockingCLI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
