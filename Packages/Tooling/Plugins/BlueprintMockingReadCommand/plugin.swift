import Foundation
import PackagePlugin

@main
struct BlueprintMockingReadCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        guard let verb = arguments.first, ["inspect", "verify-generated"].contains(verb) else {
            throw CommandError(description: "Use blueprint-mocking-read with inspect or verify-generated and the configured CLI arguments.")
        }
        let tool = try context.tool(named: "BlueprintMockingCLI")
        try invoke(tool: tool.url, in: context.package.directoryURL, arguments: arguments)
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
