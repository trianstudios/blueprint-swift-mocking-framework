import Foundation
import SwiftParser
import SwiftSyntax

struct GenerationError: Error, CustomStringConvertible {
    let description: String
}
enum Isolation {
    case sendable
    case mainActor

    var identity: String { self == .sendable ? "Sendable" : "MainActor" }
    var prefix: String { self == .mainActor ? "MainActor" : "" }
    var annotation: String { self == .mainActor ? "@MainActor " : "" }
}
struct Member {
    let name: String
    let label: String
    let inputType: String
    let outputType: String
    let failure: String?
    let identity: String
    let line: Int
    let isolation: Isolation
    var family: String { isolation.prefix + (failure == nil ? "Sync" : "AsyncThrowing") }
    var arguments: String {
        let types = "\(inputType), \(outputType)"
        return failure.map { "\(types), \($0)" } ?? types
    }
    var signature: String {
        let parameter = label == "_" ? "_ input" : label + " input"
        let effects = failure.map { " async throws(\($0))" } ?? ""
        return "\(name)(\(parameter): \(inputType))\(effects) -> \(outputType)"
    }
    var descriptorSignature: String {
        let parameter = label == "_" ? "_ matcher" : label + " matcher"
        return "\(name)(\(parameter): \(isolation.prefix)Matcher<\(inputType)>)"
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
          proto.genericWhereClause == nil, proto.modifiers.map({ $0.name.text }) == ["public"] else {
        try reject(proto, "Select a top-level, non-generic public protocol")
    }
    let conformances = proto.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
    let isolation: Isolation
    if proto.attributes.isEmpty && conformances == ["Sendable"] {
        isolation = .sendable
    } else if proto.attributes.count == 1,
              let attribute = proto.attributes.first?.as(AttributeSyntax.self),
              attribute.attributeName.trimmedDescription == "MainActor",
              attribute.leftParen == nil, attribute.arguments == nil,
              conformances.isEmpty {
        isolation = .mainActor
    } else {
        try reject(proto, "Use a public Sendable protocol without attributes or a public @MainActor protocol without inheritance")
    }

    // The consumer compiler resolves aliases and validates the conformance. Reject type
    // shapes this emitter cannot reproduce, including references to a witness's Self.
    func supportedType(_ type: TypeSyntax) -> String? {
        if isolation == .sendable { return type.trimmedDescription == "String" ? "String" : nil }
        guard let identifier = type.as(IdentifierTypeSyntax.self),
              identifier.genericArgumentClause == nil,
              simple(identifier.name.text),
              !["Self", "Never", "Void", "Stubs", "Verification", selected + "Mock"].contains(identifier.name.text) else {
            return nil
        }
        return identifier.name.text
    }
    var members: [Member] = []
    var descriptors = Set<String>()
    for item in proto.memberBlock.members {
        guard let fn = item.decl.as(FunctionDeclSyntax.self) else {
            try reject(item, "Only function requirements are supported in this slice")
        }
        let parameters = fn.signature.parameterClause.parameters
        guard fn.body == nil, fn.attributes.isEmpty, fn.modifiers.isEmpty,
              fn.genericParameterClause == nil, fn.genericWhereClause == nil,
              simple(fn.name.text), !["init", "verify", "Stubs", "Verification"].contains(fn.name.text),
              parameters.count == 1, let parameter = parameters.first,
              let inputType = supportedType(parameter.type),
              parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
              parameter.ellipsis == nil, parameter.defaultValue == nil,
              (simple(parameter.firstName.text) || parameter.firstName.text == "_"),
              let resultType = fn.signature.returnClause?.type,
              let outputType = supportedType(resultType) else {
            let shape = isolation == .sendable ? "String" : "a simple named value or reference type"
            try reject(fn, "Supported requirements take one parameter and return a value of the supported type shape (\(shape)); generics, ownership modifiers, attributes and reserved mock names are unsupported")
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
        let descriptor = "\(name)(\(label):\(inputType))"
        guard descriptors.insert(descriptor).inserted else {
            try reject(fn, "Overloads that differ only by effects or result type require separate descriptor names")
        }
        let effect = failure.map { " async throws(" + $0 + ")" } ?? ""
        let identity = "schema1|\(module).\(selected)|\(descriptor)\(effect)->\(outputType)|\(isolation.identity)"
        members.append(Member(name: name, label: label, inputType: inputType, outputType: outputType,
                              failure: failure, identity: identity,
                              line: converter.location(for: fn.positionAfterSkippingLeadingTrivia).line,
                              isolation: isolation))
    }
    guard !members.isEmpty else { try reject(proto, "The selected protocol has no supported requirements") }
    members.sort { $0.identity < $1.identity }
    let name = selected + "Mock"
    var output = """
    // Generated by the Blueprint Mocking prototype. Schema 1. Do not edit.
    // Source: \(URL(fileURLWithPath: input).lastPathComponent), protocol \(selected).
    // \((isolation == .sendable ? "Restricted Sendable/String" : "MainActor nominal types")) profile; consumer compilation is the conformance gate.
    import BlueprintMocking
    import \(module)

    \(isolation.annotation)public final class \(name): \(selected) {
        private let __schema: BlueprintRuntimeSchemaV1.Type = BlueprintRuntimeSchemaV1.self

    """
    for (i, m) in members.enumerated() {
        output += "    private let __endpoint\(i): \(m.family)Endpoint<\(m.arguments)>\n"
    }
    output += "\n    \(isolation.annotation)public struct Stubs {\n"
    for (i,m) in members.enumerated() {
        output += "        fileprivate let __setup\(i): \(m.family)Stubbing<\(m.arguments)>\n"
        output += "        public func \(m.descriptorSignature) -> \(m.family)Stub<\(m.arguments)> {\n            __setup\(i).matching(matcher)\n        }\n"
    }
    let verificationConformance = isolation == .sendable ? ": Sendable" : ""
    output += "    }\n\n    \(isolation.annotation)public struct Verification\(verificationConformance) {\n"
    for (i,m) in members.enumerated() {
        output += "        fileprivate let __endpoint\(i): \(m.family)Endpoint<\(m.arguments)>\n"
        output += "        public func \(m.descriptorSignature.dropLast()), phase: CallPhase = .admitted) -> BlueprintMocking.\(isolation.prefix)Verification<\(m.inputType)> {\n            __endpoint\(i).verification(matching: matcher, phase: phase)\n        }\n"
    }
    output += "    }\n\n    public var verify: Verification {\n        Verification(" +
        members.indices.map { "__endpoint\($0): __endpoint\($0)" }.joined(separator: ", ") + ")\n    }\n\n"
    output += "    public init(failureReporter: FailureReporter,\n"
    let failureIsolation = isolation == .sendable ? "@Sendable" : "@MainActor"
    for (i,m) in members.enumerated() {
        guard let failure = m.failure else { continue }
        output += "                failureMapping\(i): (\(failureIsolation) (MockIssue) -> \(failure))? = nil,\n"
    }
    output += "                _ configure: \(isolation.annotation)(Stubs) -> Void) {\n"
    for (i,m) in members.enumerated() {
        output += "        let setup\(i) = \(m.family)Stubbing<\(m.arguments)>()\n"
    }
    output += "        configure(Stubs(" + members.indices.map { "__setup\($0): setup\($0)" }.joined(separator: ", ") + "))\n"
    for (i,m) in members.enumerated() {
        output += "        self.__endpoint\(i) = \(m.family)Endpoint(id: EndpointID(\(String(reflecting: m.identity))),\n            configuration: setup\(i).finish(), failureReporter: failureReporter\(m.failure != nil ? ", failureMapping: failureMapping" + String(i) : ""))\n"
    }
    output += "    }\n"
    for (i,m) in members.enumerated() {
        let file = module + "/" + URL(fileURLWithPath: input).lastPathComponent
        output += "\n    public func \(m.signature) {\n        \(m.failure != nil ? "try await " : "")__endpoint\(i).invoke(input, source: SourceLocation(fileID: \(String(reflecting: file)), filePath: \(String(reflecting: URL(fileURLWithPath: input).lastPathComponent)), line: \(m.line), column: 1))\n    }\n"
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
