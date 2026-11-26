import Foundation
import PackagePlugin

@main
struct BlueprintMockingBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        guard target is SwiftSourceModuleTarget else {
            throw PluginInputError(description: "Attach BlueprintMockingBuildPlugin to a Swift test or test-support target.")
        }

        let packageDirectory = context.package.directoryURL
        let configuration = packageDirectory.appendingPathComponent("blueprint-mocking.json")
        guard FileManager.default.fileExists(atPath: configuration.path) else {
            throw PluginInputError(description: "Add blueprint-mocking.json at the root of the consuming package.")
        }

        let localTargetIDs = Set(context.package.targets.map(\.id))
        let modules = target.dependencies.compactMap { dependency -> SwiftSourceModuleTarget? in
            guard case .target(let source) = dependency, localTargetIDs.contains(source.id) else { return nil }
            return source as? SwiftSourceModuleTarget
        }

        let directoryComponents = packageDirectory.standardizedFileURL.pathComponents
        var sources: [Source] = []
        for module in modules {
            for file in module.sourceFiles(withSuffix: "swift") {
                let url = file.url.standardizedFileURL
                let components = url.pathComponents
                guard components.starts(with: directoryComponents), components.count > directoryComponents.count else {
                    throw PluginInputError(description: "Swift source for \(module.moduleName) must be inside its package.")
                }
                let relativePath = components.dropFirst(directoryComponents.count).joined(separator: "/")
                sources.append(Source(module: module.moduleName, url: url, relativePath: relativePath))
            }
        }
        guard !sources.isEmpty else {
            throw PluginInputError(description: "Add a direct Swift source target dependency from this package to \(target.name).")
        }
        sources.sort {
            if $0.module.utf8.elementsEqual($1.module.utf8) {
                return $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
            }
            return $0.module.utf8.lexicographicallyPrecedes($1.module.utf8)
        }

        let tool = try context.tool(named: "BlueprintMockingCLI")
        let outputDirectory = context.pluginWorkDirectoryURL
        var arguments = [
            "generate", "--config", configuration.path, "--output", outputDirectory.path,
            "--input-set-id", inputSetID(for: sources)
        ]
        for source in sources {
            arguments.append(contentsOf: ["--source", source.module, source.url.path])
        }

        return [
            .buildCommand(
                displayName: "Generate Blueprint mocks for \(target.name)",
                executable: tool.url,
                arguments: arguments,
                inputFiles: [configuration] + sources.map(\.url),
                outputFiles: [
                    outputDirectory.appendingPathComponent("BlueprintMocks.generated.swift"),
                    outputDirectory.appendingPathComponent("BlueprintMockingIndex.generated.swift")
                ]
            )
        ]
    }

    private struct Source {
        let module: String
        let url: URL
        let relativePath: String
    }

    private struct PluginInputError: Error, CustomStringConvertible {
        let description: String
    }

    private func inputSetID(for sources: [Source]) -> String {
        // Hash sorted identities with separators that cannot occur in a path or module name.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for source in sources {
            for byte in "\(source.module)\0\(source.relativePath)\0".utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        return String(hash, radix: 16)
    }
}
