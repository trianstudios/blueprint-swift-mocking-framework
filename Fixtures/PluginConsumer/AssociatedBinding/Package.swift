// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginAssociatedBindingConsumer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AssociatedPluginProbe", targets: ["AssociatedPluginProbe"])],
    dependencies: [
        .package(name: "BluepringMockingFramework", path: "../../.."),
        .package(name: "BlueprintMockingTools", path: "../../../Packages/Tooling"),
    ],
    targets: [
        .target(name: "AssociatedPluginDomain"),
        .target(name: "AssociatedPluginMocks", dependencies: [
            "AssociatedPluginDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ], plugins: [
            .plugin(name: "BlueprintMockingBuildPlugin", package: "BlueprintMockingTools"),
        ]),
        .executableTarget(name: "AssociatedPluginProbe", dependencies: [
            "AssociatedPluginDomain", "AssociatedPluginMocks",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
