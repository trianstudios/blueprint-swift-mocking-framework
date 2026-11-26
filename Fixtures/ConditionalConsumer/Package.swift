// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConditionalConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [
        .target(name: "ConditionalDomain", swiftSettings: [.define("BLUEPRINT_DOMAIN_INT")]),
        .target(name: "ConditionalDoubles", dependencies: [
            "ConditionalDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
        ]),
        .testTarget(name: "ConditionalProbe", dependencies: [
            "ConditionalDomain", "ConditionalDoubles",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
            .product(name: "BlueprintMockingTesting", package: "BluepringMockingFramework"),
        ], swiftSettings: [.define("BLUEPRINT_PROBE_FIXTURE")]),
    ],
    swiftLanguageModes: [.v6]
)
