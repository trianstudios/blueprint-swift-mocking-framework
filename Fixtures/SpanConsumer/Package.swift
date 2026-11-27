// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpanConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [
        .target(name: "SpanDomain"),
        .target(name: "SpanDoubles", dependencies: [
            "SpanDomain", .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ]),
        .testTarget(name: "SpanConsumerTests", dependencies: [
            "SpanDomain", "SpanDoubles", .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ])
    ],
    swiftLanguageModes: [.v6]
)
