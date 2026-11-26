import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct BuildConfiguration: Codable {
    struct Selection: Codable {
        let module: String
        let type: String
        let kind: String
        let associatedTypeBindings: [AssociatedTypeBinding]?
    }

    let schemaVersion: Int
    let selections: [Selection]
}

private func invalid(_ message: String) -> GenerationError {
    GenerationError(description: "error: BPM002: \(message)")
}

private func loadConfiguration(_ url: URL) throws -> BuildConfiguration {
    let data = try Data(contentsOf: url)
    let requiredSelectionKeys: Set<String> = ["module", "type", "kind"]
    let selectionKeys = requiredSelectionKeys.union(["associatedTypeBindings"])
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["schemaVersion", "selections"],
          let selections = object["selections"] as? [[String: Any]],
          selections.allSatisfy({ requiredSelectionKeys.isSubset(of: $0.keys) && Set($0.keys).isSubset(of: selectionKeys) }) else {
        throw invalid("Expected schemaVersion and selections with module, type and kind in \(url.lastPathComponent)")
    }
    for selection in selections {
        guard let bindings = selection["associatedTypeBindings"] else { continue }
        guard let entries = bindings as? [[String: Any]], entries.allSatisfy({
            Set($0.keys) == ["name", "type"] && $0["name"] is String && $0["type"] is String
        }) else {
            throw invalid("Expected associatedTypeBindings to contain name and type strings in \(url.lastPathComponent)")
        }
    }
    let configuration = try JSONDecoder().decode(BuildConfiguration.self, from: data)
    guard configuration.schemaVersion == 1 else {
        throw invalid("Unsupported generation configuration schema \(configuration.schemaVersion)")
    }
    guard configuration.selections.allSatisfy({ $0.kind == "protocol" }) else {
        throw invalid("SwiftPM source generation supports protocol selections")
    }
    let types = Set(configuration.selections.map(\.type))
    guard types.count == configuration.selections.count,
          types.isDisjoint(with: types.map { $0 + "Mock" }) else {
        throw invalid("Selected protocols would produce conflicting generated names")
    }
    return configuration
}

private struct BuildGenerationRequest {
    let config: URL
    let output: URL
    let inputSetID: String
    let sources: [String: [String]]
    let sourceConditions: [String: [String: Bool]]

    init(arguments: ArraySlice<String>, command: String) throws {
        let usage = invalid("usage: blueprint-mocking \(command) --config PATH --output DIRECTORY "
                            + "--input-set-id HEX [--source MODULE FILE]... [--source-condition MODULE FLAG true|false]..."
                            + (command == "inspect" ? " [--format json]" : ""))
        var arguments = arguments
        guard arguments.popFirst() == "--config", let configPath = arguments.popFirst(),
              arguments.popFirst() == "--output", let outputPath = arguments.popFirst(),
              arguments.popFirst() == "--input-set-id", let inputSetID = arguments.popFirst(),
              (1...16).contains(inputSetID.count), inputSetID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw usage }

        var sources: [String: [String]] = [:]
        var conditions = ExplicitSourceConditions()
        var seen: Set<String> = []
        var hasFormat = false
        while let option = arguments.popFirst() {
            if command == "inspect", option == "--format" {
                guard !hasFormat, arguments.popFirst() == "json" else { throw usage }
                hasFormat = true
                continue
            }
            if option == "--source-condition" {
                try conditions.read(from: &arguments)
                continue
            }
            guard option == "--source", let module = arguments.popFirst(), let path = arguments.popFirst() else {
                throw usage
            }
            guard seen.insert(path).inserted else { throw invalid("Duplicate Swift source input \(path)") }
            sources[module, default: []].append(path)
        }
        self.config = URL(fileURLWithPath: configPath)
        self.output = URL(fileURLWithPath: outputPath, isDirectory: true)
        self.inputSetID = inputSetID
        self.sources = sources
        self.sourceConditions = conditions.values
    }
}

private func fingerprint(_ contents: String) -> String {
    // Stable identity for the generated index. Artifact verification uses other digests.
    let hash = contents.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    return String(hash, radix: 16)
}

private let shardName = "BlueprintMocks.generated.swift"
private let indexName = "BlueprintMockingIndex.generated.swift"
private let interruptedPublication = GenerationError(
    description: "error: BPM004: Interrupted generated output publication. Rerun generation to recover."
)
private let dirtyIndex = Data("""
    #error("Blueprint Mocking: interrupted output publication. Rerun generation to recover.")

    """.utf8)

private struct BuildOutputPair: Codable, Equatable {
    let shard: Data?
    let index: Data?
}

private struct PublicationJournal: Codable {
    let schema: Int
    let previous: BuildOutputPair
    let next: BuildOutputPair
}

private func withOutputLock<T>(_ directory: URL, exclusive: Bool, body: () throws -> T) throws -> T {
    #if canImport(Darwin) || canImport(Glibc)
    // Lock the work directory inode so successful publication leaves exactly the two declared outputs.
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = close(descriptor) }
    let operation = exclusive ? LOCK_EX : LOCK_SH
    var result = flock(descriptor, operation)
    while result != 0 && errno == EINTR {
        result = flock(descriptor, operation)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return try body()
    #else
    throw GenerationError(description: "error: BPM004: Output directory locking is unavailable on this host.")
    #endif
}

private func regularData(at url: URL) throws -> Data? {
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw GenerationError(description: "error: BPM004: Generated path is not a regular file: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        return nil
    }
}

private func replaceGeneratedFile(at url: URL, with data: Data?) throws {
    let current = try regularData(at: url)
    guard data != current else { return }
    if let data {
        try data.write(to: url, options: .atomic)
    } else {
        try FileManager.default.removeItem(at: url)
    }
}

// Only the separately built verification tool can terminate at these boundaries.
private func publicationCheckpoint(_ checkpoint: String) {
    #if BLUEPRINT_TEST_PUBLICATION && (canImport(Darwin) || canImport(Glibc))
    if ProcessInfo.processInfo.environment["BLUEPRINT_TEST_PUBLICATION_CHECKPOINT"] == checkpoint {
        FileHandle.standardError.write(Data("DX013 fixture: interrupted at \(checkpoint)\n".utf8))
        _exit(93)
    }
    #endif
}

private struct BuildOutputPublication {
    let shard: URL
    let index: URL
    let journal: URL

    init(directory: URL) {
        shard = directory.appendingPathComponent(shardName)
        index = directory.appendingPathComponent(indexName)
        journal = directory.appendingPathComponent(".blueprint-mocking-transaction.json")
    }

    private func currentPair() throws -> BuildOutputPair {
        try BuildOutputPair(shard: regularData(at: shard), index: regularData(at: index))
    }

    func requireClean() throws {
        if try regularData(at: journal) != nil {
            throw interruptedPublication
        }
    }

    private func recover() throws {
        guard let bytes = try regularData(at: journal) else { return }
        guard let record = try? JSONDecoder().decode(PublicationJournal.self, from: bytes),
              record.schema == 1, record.next.shard != nil, record.next.index != nil else {
            throw GenerationError(description: "error: BPM004: Invalid generated output recovery journal.")
        }

        let current = try currentPair()
        if current != record.previous && current != record.next {
            try replaceGeneratedFile(at: index, with: dirtyIndex)
            try replaceGeneratedFile(at: shard, with: record.previous.shard)
            publicationCheckpoint("recovery-after-shard")
            try replaceGeneratedFile(at: index, with: record.previous.index)
            publicationCheckpoint("recovery-after-index")
            guard try currentPair() == record.previous else { throw interruptedPublication }
        }
        try FileManager.default.removeItem(at: journal)
        publicationCheckpoint("recovery-after-journal-removal")
    }

    func publish(shard newShard: Data, index newIndex: Data) throws {
        try recover()
        // Read and validate both destinations before staging or replacing either one.
        let previous = try currentPair()
        let next = BuildOutputPair(shard: newShard, index: newIndex)
        guard previous != next else { return }
        let record = PublicationJournal(schema: 1, previous: previous, next: next)
        publicationCheckpoint("before-journal")
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        publicationCheckpoint("after-journal")

        // The index blocks compilation during the fixed-path transition until published last.
        try replaceGeneratedFile(at: index, with: dirtyIndex)
        publicationCheckpoint("after-dirty-index")
        try replaceGeneratedFile(at: shard, with: newShard)
        publicationCheckpoint("after-shard")
        guard try regularData(at: shard) == newShard else { throw interruptedPublication }
        try replaceGeneratedFile(at: index, with: newIndex)
        publicationCheckpoint("after-index")
        guard try currentPair() == next else { throw interruptedPublication }
        try FileManager.default.removeItem(at: journal)
        publicationCheckpoint("after-journal-removal")
    }
}

private struct BuildGenerationPlan {
    struct Selection {
        let selected: BuildConfiguration.Selection
        let origin: ProtocolSourceOrigin
        let mock: GeneratedProtocolMock
    }

    let configuration: BuildConfiguration
    let selections: [Selection]
    let outputs: [(url: URL, text: String)]

    init(request: BuildGenerationRequest) throws {
        let loaded = try loadConfiguration(request.config)
        let sorted = loaded.selections.sorted { ($0.module, $0.type) < ($1.module, $1.type) }
        let sourceIndex = ProtocolSourceIndex(sources: request.sources, conditions: request.sourceConditions)
        let resolved = try sorted.map { selection in
            let root = try sourceIndex.select(selection.type, in: selection.module, diagnosticFile: request.config.path)
            let mock = try generate(index: sourceIndex, root: root, projections: [],
                                    variadicForwarding: [], subscriptSpecializations: [], spy: false,
                                    associatedTypeBindings: selection.associatedTypeBindings ?? [])
            let normalized = BuildConfiguration.Selection(
                module: selection.module, type: selection.type, kind: selection.kind,
                associatedTypeBindings: mock.associatedTypeBindings.isEmpty ? nil : mock.associatedTypeBindings
            )
            return Selection(selected: normalized, origin: root.origin, mock: mock)
        }
        selections = resolved
        configuration = BuildConfiguration(schemaVersion: loaded.schemaVersion, selections: resolved.map(\.selected))

        let body = resolved.map { $0.mock.source }.joined(separator: "\n")
        let marker = "BlueprintMockingShard_" + fingerprint(body)
        let header = "// Generated by Blueprint Mocking. Do not edit.\n"
        let shard = header + body + "\nenum \(marker) {}\n"
        let index = header + "// SwiftPM input set: \(request.inputSetID)\n"
            + "enum BlueprintMockingGeneratedIndex { typealias Shard = \(marker) }\n"
        outputs = [
            (request.output.appendingPathComponent(shardName), shard),
            (request.output.appendingPathComponent(indexName), index),
        ]
        for (url, _) in outputs {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw invalid("Generated output is a symbolic link: \(url.lastPathComponent)")
            }
        }
    }
}

private struct BuildInspection: Encodable {
    struct Input: Encodable {
        let module: String
        let path: String
    }

    struct Inputs: Encodable {
        let configuration: String
        let sources: [Input]
        let sourceConditions: [String: [String: Bool]]?
    }

    struct Declaration: Encodable {
        let module: String
        let type: String
        let kind: String
        let file: String
        let line: Int
        let generatedType: String
    }

    struct Ownership: Encodable {
        let owner: String
        let files: [String]
    }

    let schemaVersion = 1
    let configuration: BuildConfiguration
    let inputSetID: String
    let inputs: Inputs
    let declarations: [Declaration]
    let outputOwnership: Ownership
    let featureGates = [
        "analysis": "supplied-swift-sources",
        "compilerContext": "unavailable",
        "protocolInheritance": "supplied-source-index",
    ]

    init(request: BuildGenerationRequest, plan: BuildGenerationPlan) {
        let config = request.config.standardizedFileURL
        let base = config.deletingLastPathComponent().pathComponents
        func reportPath(_ url: URL) -> String {
            let file = url.standardizedFileURL
            let components = file.pathComponents
            guard components.starts(with: base) else { return file.path }
            return components.dropFirst(base.count).joined(separator: "/")
        }

        configuration = plan.configuration
        inputSetID = request.inputSetID
        let sources = request.sources.keys.sorted().flatMap { module in
            let paths = Set((request.sources[module] ?? []).map { reportPath(URL(fileURLWithPath: $0)) })
            return paths.sorted().map { Input(module: module, path: $0) }
        }
        inputs = Inputs(configuration: reportPath(config), sources: sources,
                        sourceConditions: request.sourceConditions.isEmpty ? nil : request.sourceConditions)
        declarations = plan.selections.map { selection in
            Declaration(module: selection.selected.module, type: selection.selected.type,
                        kind: selection.selected.kind, file: reportPath(URL(fileURLWithPath: selection.origin.path)),
                        line: selection.origin.line, generatedType: selection.mock.typeName)
        }
        outputOwnership = Ownership(owner: "BlueprintMockingBuildPlugin",
                                    files: plan.outputs.map { reportPath($0.url) })
    }
}

func inspectBuildOutputs(arguments: ArraySlice<String>) throws {
    let request = try BuildGenerationRequest(arguments: arguments, command: "inspect")
    let plan = try BuildGenerationPlan(request: request)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var report = try encoder.encode(BuildInspection(request: request, plan: plan))
    report.append(0x0a)
    FileHandle.standardOutput.write(report)
}

struct GeneratedOutputMismatch: Error, CustomStringConvertible {
    let files: [URL]

    var description: String {
        (["error: BPM003: Generated files differ:"] + files.map { "  \($0.path)" }).joined(separator: "\n")
    }
}

func verifyBuildOutputs(arguments: ArraySlice<String>) throws {
    let request = try BuildGenerationRequest(arguments: arguments, command: "verify-generated")
    guard FileManager.default.fileExists(atPath: request.output.path) else {
        let plan = try BuildGenerationPlan(request: request)
        throw GeneratedOutputMismatch(files: plan.outputs.map(\.url))
    }
    try withOutputLock(request.output, exclusive: false) {
        try BuildOutputPublication(directory: request.output).requireClean()
        let plan = try BuildGenerationPlan(request: request)
        let mismatched = try plan.outputs.compactMap { url, text in
            try regularData(at: url) == Data(text.utf8) ? nil : url
        }
        guard mismatched.isEmpty else { throw GeneratedOutputMismatch(files: mismatched) }
        print("Blueprint Mocking: verified \(plan.outputs.count) generated file(s)")
    }
}

func generateBuildOutputs(arguments: ArraySlice<String>) throws {
    let request = try BuildGenerationRequest(arguments: arguments, command: "generate")
    if !FileManager.default.fileExists(atPath: request.output.path) {
        // A rejected first request must not create its output directory.
        _ = try BuildGenerationPlan(request: request)
        try FileManager.default.createDirectory(at: request.output, withIntermediateDirectories: true)
    }
    try withOutputLock(request.output, exclusive: true) {
        let plan = try BuildGenerationPlan(request: request)
        try BuildOutputPublication(directory: request.output).publish(
            shard: Data(plan.outputs[0].text.utf8), index: Data(plan.outputs[1].text.utf8)
        )
        print("Blueprint Mocking: generated \(plan.selections.count) protocol mock(s)")
    }
}
