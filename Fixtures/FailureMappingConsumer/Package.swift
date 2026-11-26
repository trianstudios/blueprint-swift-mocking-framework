// swift-tools-version: 6.0
import Foundation
import PackageDescription

let frameworkPath = ProcessInfo.processInfo.environment["BLUEPRINT_FAILURE_MAPPING_FRAMEWORK_PATH"] ?? "../.."

let package = Package(
    name: "FailureMappingConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "BluepringMockingFramework", path: frameworkPath)],
    targets: [
        .target(name: "ProbeDomain"),
        .target(name: "ProbeDoubles", dependencies: [
            "ProbeDomain",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ]),
        .testTarget(name: "FailureMappingProbeTests", dependencies: [
            "ProbeDomain", "ProbeDoubles",
            .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")
        ])
    ],
    swiftLanguageModes: [.v6]
)
