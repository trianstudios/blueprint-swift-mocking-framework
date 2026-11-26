// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XCTestConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [
        .target(name: "LookupDomain"),
        .testTarget(name: "XCTestConsumerTests", dependencies: [
            "LookupDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
            .product(name: "BlueprintMockingXCTest", package: "BluepringMockingFramework")
        ])
    ],
    swiftLanguageModes: [.v6]
)
