// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginConsumer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PluginProbe", targets: ["PluginProbe"])],
    dependencies: [
        .package(name: "BluepringMockingFramework", path: "../.."),
        .package(name: "BlueprintMockingTools", path: "../../Packages/Tooling"),
    ],
    targets: [
        .target(name: "PluginDomain"),
        .target(name: "PluginMocks", dependencies: [
            "PluginDomain", .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ], plugins: [
            .plugin(name: "BlueprintMockingBuildPlugin", package: "BlueprintMockingTools"),
        ]),
        .executableTarget(name: "PluginProbe", dependencies: [
            "PluginDomain", "PluginMocks",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
