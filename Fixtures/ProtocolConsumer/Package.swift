// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProtocolConsumer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "consumer-demo", targets: ["ConsumerDemo"]),
        .executable(name: "SubclassBootstrapProbe", targets: ["SubclassBootstrapProbe"])
    ],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [
        .target(name: "BootstrapDomain"),
        .executableTarget(name: "SubclassBootstrapProbe", dependencies: [
            "BootstrapDomain", .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ]),
        .target(name: "ParentDomain"),
        .target(name: "ConsumerDomain", dependencies: ["ParentDomain"]),
        .target(name: "ConsumerDoubles", dependencies: [
            "ConsumerDomain", "ParentDomain", .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ]),
        .executableTarget(name: "ConsumerDemo", dependencies: [
            "ConsumerDomain", "ConsumerDoubles",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ]),
        .testTarget(name: "ConsumerTests", dependencies: [
            "ConsumerDomain", "ConsumerDoubles", "ParentDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
            .product(name: "BlueprintMockingTesting", package: "BluepringMockingFramework")
        ])
    ],
    swiftLanguageModes: [.v6]
)
