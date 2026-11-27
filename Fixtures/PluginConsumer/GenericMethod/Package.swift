// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginGenericMethodConsumer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GenericMethodPluginProbe", targets: ["GenericMethodPluginProbe"])],
    dependencies: [
        .package(name: "BluepringMockingFramework", path: "../../.."),
        .package(name: "BlueprintMockingTools", path: "../../../Packages/Tooling"),
    ],
    targets: [
        .target(name: "GenericMethodPluginDomain"),
        .target(name: "GenericMethodPluginMocks", dependencies: [
            "GenericMethodPluginDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ], plugins: [
            .plugin(name: "BlueprintMockingBuildPlugin", package: "BlueprintMockingTools"),
        ]),
        .executableTarget(name: "GenericMethodPluginProbe", dependencies: [
            "GenericMethodPluginDomain", "GenericMethodPluginMocks",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
