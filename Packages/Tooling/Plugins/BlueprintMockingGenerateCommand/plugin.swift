import Foundation
import PackagePlugin
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct BlueprintMockingGenerateCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        guard arguments.count >= 6, arguments[0] == "--config",
              arguments[2] == "--output", arguments[4] == "--input-set-id" else {
            throw CommandError(description: "Use blueprint-mocking-generate with --config PATH --output DIRECTORY --input-set-id HEX and the configured CLI inputs.")
        }
        let tool = try context.tool(named: "BlueprintMockingCLI")
        let package = context.package.directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = try newDestination(arguments[3], in: package)
        #if canImport(Darwin) || canImport(Glibc)
        // Reserve the fresh name atomically so concurrent invocations cannot reuse it.
        guard mkdir(destination.path, 0o755) == 0 else {
            let cause = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw CommandError(description: "Pass a new package-relative output directory with an existing parent: \(cause).")
        }
        var toolArguments = ["generate"] + arguments
        toolArguments[4] = destination.path
        do {
            try invoke(tool: tool.url, in: package, arguments: toolArguments)
        } catch {
            // Remove only an empty reservation. Preserve any recoverable CLI publication state.
            _ = rmdir(destination.path)
            throw error
        }
        #else
        throw CommandError(description: "Fresh command-plugin output reservation is unavailable on this host.")
        #endif
    }

    private func newDestination(_ path: String, in package: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.utf8.contains(0), !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CommandError(description: "Pass a normalized package-relative output directory.")
        }
        let destination = package.appendingPathComponent(path, isDirectory: true)
        let parent = destination.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path else {
            throw CommandError(description: "The output directory parent must not use a symbolic link.")
        }
        return destination
    }

    private func invoke(tool: URL, in package: URL, arguments: [String]) throws {
        let invocation = try JSONSerialization.data(withJSONObject: [
            "workingDirectory": package.path, "executable": tool.path, "arguments": arguments
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardError.write(Data("Blueprint Mocking invocation: ".utf8) + invocation + Data([10]))
        let process = Process()
        process.executableURL = tool
        process.currentDirectoryURL = package
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let reason = process.terminationReason == .exit ? "status" : "signal"
            throw CommandError(description: "Blueprint Mocking CLI ended with \(reason) \(process.terminationStatus).")
        }
    }

    private struct CommandError: Error, CustomStringConvertible {
        let description: String
    }
}
