// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OfflineGenerationConsumer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OfflineProbe", targets: ["OfflineProbe"])],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [
        .target(name: "OfflineDomain"),
        .executableTarget(name: "OfflineProbe", dependencies: [
            "OfflineDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ])
    ],
    swiftLanguageModes: [.v6]
)
