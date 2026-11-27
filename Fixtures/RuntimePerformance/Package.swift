// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimePerformance",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [.executableTarget(name: "RuntimePerformanceProbe", dependencies: [
        .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
    ])],
    swiftLanguageModes: [.v6]
)
