// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RuntimeOnly",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
    targets: [.executableTarget(name: "RuntimeOnly", dependencies: [
        .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
    ])],
    swiftLanguageModes: [.v6]
)
