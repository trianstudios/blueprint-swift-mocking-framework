// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LegacyProcessConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [.executableTarget(name: "LegacyProcessChild", dependencies: [
        .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
    ])],
    swiftLanguageModes: [.v6]
)
