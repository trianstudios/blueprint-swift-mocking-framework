import Foundation
import SwiftParser
import SwiftSyntax

struct GenerationError: Error, CustomStringConvertible {
    let description: String
}
struct Member {
    let name: String
    let label: String
    let failure: String?
    let identity: String
    let line: Int
    var async: Bool { failure != nil }
    var family: String { async ? "AsyncThrowing" : "Sync" }
    var arguments: String { async ? "String, String, \(failure!)" : "String, String" }
    var signature: String {
        "\(name)(\(label == "_" ? "_ input" : label + " input"): String)\(async ? " async throws(" + failure! + ")" : "") -> String"
    }
    var descriptorSignature: String {
        "\(name)(\(label == "_" ? "_ matcher" : label + " matcher"): Matcher<String>)"
    }
}
func generate(input: String, module: String, selected: String) throws -> String {
    let source = try String(contentsOfFile: input, encoding: .utf8)
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: input, tree: tree)
    func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        throw GenerationError(description: "\(input):\(location.line):\(location.column): error: BPM001: \(message)")
    }
    guard !tree.hasError else { try reject(tree, "Malformed Swift source; fix parser errors before generation") }
    let candidates = tree.statements.compactMap { $0.item.as(ProtocolDeclSyntax.self) }
        .filter { $0.name.text == selected }
    guard candidates.count == 1, let proto = candidates.first else {
        try reject(tree, "Select one top-level protocol; conditional/nested/imported discovery is not supported")
    }
    func simple(_ name: String) -> Bool {
        !name.isEmpty && name.first!.isLetter &&
        name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
    guard simple(module), simple(selected), proto.primaryAssociatedTypeClause == nil,
          proto.genericWhereClause == nil, proto.attributes.isEmpty,
          proto.modifiers.map({ $0.name.text }) == ["public"],
          proto.inheritanceClause?.inheritedTypes.map({ $0.type.trimmedDescription }) == ["Sendable"] else {
        try reject(proto, "This slice requires a non-generic public protocol inheriting only Sendable, without attributes; actor/ordinary profiles and inheritance remain roadmap work")
    }
    var members: [Member] = []
    var identities = Set<String>()
    for item in proto.memberBlock.members {
        guard let fn = item.decl.as(FunctionDeclSyntax.self) else {
            try reject(item, "Only function requirements are supported in this slice")
        }
        let parameters = fn.signature.parameterClause.parameters
        guard fn.body == nil, fn.attributes.isEmpty, fn.modifiers.isEmpty,
              fn.genericParameterClause == nil, fn.genericWhereClause == nil,
              simple(fn.name.text), !["init", "verify", "Stubs", "Verification"].contains(fn.name.text),
              parameters.count == 1, let parameter = parameters.first,
              parameter.type.trimmedDescription == "String",
              parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
              parameter.ellipsis == nil, parameter.defaultValue == nil,
              (simple(parameter.firstName.text) || parameter.firstName.text == "_"),
              fn.signature.returnClause?.type.trimmedDescription == "String" else {
            try reject(fn, "Supported requirements have one String parameter and a String result, with no generics, ownership modifiers, attributes or reserved mock names")
        }
        let effects = fn.signature.effectSpecifiers
        var failure: String?
        if effects != nil {
            guard effects?.asyncSpecifier?.text == "async",
                  let thrown = effects?.throwsClause,
                  thrown.throwsSpecifier.text == "throws",
                  let type = thrown.type?.as(IdentifierTypeSyntax.self),
                  type.genericArgumentClause == nil, simple(type.name.text) else {
                try reject(fn, "Use synchronous nonthrowing or async throws(NamedError); other effect families are not implemented")
            }
            failure = type.name.text
        }
        let name = fn.name.text
        let label = parameter.firstName.text
        let identity = "schema1|\(module).\(selected)|\(name)(\(label):String)\(failure.map { " async throws(" + $0 + ")" } ?? "")->String|Sendable"
        guard identities.insert(identity).inserted else {
            try reject(fn, "Duplicate endpoint signature")
        }
        members.append(Member(name: name, label: label, failure: failure, identity: identity,
                              line: converter.location(for: fn.positionAfterSkippingLeadingTrivia).line))
    }
    guard !members.isEmpty else { try reject(proto, "The selected protocol has no supported requirements") }
    members.sort { $0.identity < $1.identity }
    let name = selected + "Mock"
    var output = """
    // Generated by the Blueprint Mocking prototype. Schema 1. Do not edit.
    // Source: \(URL(fileURLWithPath: input).lastPathComponent), protocol \(selected).
    // Restricted Sendable/String profile; consumer compilation is the conformance gate.
    import BlueprintMocking
    import \(module)

    public final class \(name): \(selected) {
        private let __schema: BlueprintRuntimeSchemaV1.Type = BlueprintRuntimeSchemaV1.self

    """
    for (i, m) in members.enumerated() {
        output += "    private let __endpoint\(i): \(m.family)Endpoint<\(m.arguments)>\n"
    }
    output += "\n    public struct Stubs {\n"
    for (i,m) in members.enumerated() {
        output += "        fileprivate let __setup\(i): \(m.family)Stubbing<\(m.arguments)>\n"
        output += "        public func \(m.descriptorSignature) -> \(m.family)Stub<\(m.arguments)> {\n            __setup\(i).matching(matcher)\n        }\n"
    }
    output += "    }\n\n    public struct Verification: Sendable {\n"
    for (i,m) in members.enumerated() {
        output += "        fileprivate let __endpoint\(i): \(m.family)Endpoint<\(m.arguments)>\n"
        output += "        public func \(m.descriptorSignature.dropLast()), phase: CallPhase = .admitted) -> BlueprintMocking.Verification<String> {\n            __endpoint\(i).verification(matching: matcher, phase: phase)\n        }\n"
    }
    output += "    }\n\n    public var verify: Verification {\n        Verification(" +
        members.indices.map { "__endpoint\($0): __endpoint\($0)" }.joined(separator: ", ") + ")\n    }\n\n"
    output += "    public init(failureReporter: FailureReporter,\n"
    for (i,m) in members.enumerated() where m.async {
        output += "                failureMapping\(i): (@Sendable (MockIssue) -> \(m.failure!))? = nil,\n"
    }
    output += "                _ configure: (Stubs) -> Void) {\n"
    for (i,m) in members.enumerated() {
        output += "        let setup\(i) = \(m.family)Stubbing<\(m.arguments)>()\n"
    }
    output += "        configure(Stubs(" + members.indices.map { "__setup\($0): setup\($0)" }.joined(separator: ", ") + "))\n"
    for (i,m) in members.enumerated() {
        output += "        self.__endpoint\(i) = \(m.family)Endpoint(id: EndpointID(\(String(reflecting: m.identity))),\n            configuration: setup\(i).finish(), failureReporter: failureReporter\(m.async ? ", failureMapping: failureMapping" + String(i) : ""))\n"
    }
    output += "    }\n"
    for (i,m) in members.enumerated() {
        let file = module + "/" + URL(fileURLWithPath: input).lastPathComponent
        output += "\n    public func \(m.signature) {\n        \(m.async ? "try await " : "")__endpoint\(i).invoke(input, source: SourceLocation(fileID: \(String(reflecting: file)), filePath: \(String(reflecting: URL(fileURLWithPath: input).lastPathComponent)), line: \(m.line), column: 1))\n    }\n"
    }
    return output + "}\n"
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 8, arguments[0] == "--input", arguments[2] == "--module",
          arguments[4] == "--protocol", arguments[6] == "--output" else {
        throw GenerationError(description: "usage: generate --input source.swift --module Module --protocol Protocol --output Mock.swift")
    }
    let output = try generate(input: arguments[1], module: arguments[3], selected: arguments[5])
    // Parsing and validation finish before publication. No partial output on unsupported input.
    try output.write(toFile: arguments[7], atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
