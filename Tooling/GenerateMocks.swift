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
enum FailureEffect {
    case ordinary
    case typed(String)
    case never

    var type: String {
        switch self {
        case .ordinary: "any Error"
        case .typed(let type): type
        case .never: "Never"
        }
    }

    var declaration: String {
        switch self {
        case .ordinary: " throws"
        case .typed(let type): " throws(\(type))"
        case .never: " throws(Never)"
        }
    }

    var isOrdinary: Bool {
        if case .ordinary = self { return true }
        return false
    }
}
struct Effect {
    let isAsync: Bool
    let failure: FailureEffect?

    var runtimeFailure: FailureEffect? {
        if case .never? = failure { return nil }
        return failure
    }

    var family: String {
        switch (isAsync, runtimeFailure != nil) {
        case (false, false): "Sync"
        case (false, true): "SyncThrowing"
        case (true, false): "Async"
        case (true, true): "AsyncThrowing"
        }
    }

    var declaration: String {
        (isAsync ? " async" : "") + (failure?.declaration ?? "")
    }

    var callPrefix: String {
        (runtimeFailure != nil ? "try " : "") + (isAsync ? "await " : "")
    }
}
struct Member {
    let name: String
    let label: String
    let inputType: String
    let outputType: String
    let effect: Effect
    let identity: String
    let line: Int
    let isolation: Isolation
    var family: String { isolation.prefix + effect.family }
    var arguments: String {
        let types = "\(inputType), \(outputType)"
        return effect.runtimeFailure.map { "\(types), \($0.type)" } ?? types
    }
    var signature: String {
        let parameter = label == "_" ? "_ input" : label + " input"
        return "\(name)(\(parameter): \(inputType))\(effect.declaration) -> \(outputType)"
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
    func supportedResult(_ type: TypeSyntax?) -> String? {
        if isolation == .sendable {
            guard let type else { return "Void" }
            if type.trimmedDescription == "Void" || type.as(TupleTypeSyntax.self)?.elements.isEmpty == true {
                return "Void"
            }
            if type.trimmedDescription == "Never" { return "Never" }
        }
        return type.flatMap(supportedType)
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
              let outputType = supportedResult(fn.signature.returnClause?.type) else {
            let shape = isolation == .sendable ? "String input and String, Void or Never result" : "a simple named value or reference type"
            try reject(fn, "Supported requirements take one parameter and return a value of the supported type shape (\(shape)); generics, ownership modifiers, attributes and reserved mock names are unsupported")
        }
        let specifiers = fn.signature.effectSpecifiers
        if let asyncSpecifier = specifiers?.asyncSpecifier, asyncSpecifier.text != "async" {
            try reject(fn, "Only async method effects are supported")
        }
        let isAsync = specifiers?.asyncSpecifier != nil
        var failure: FailureEffect?
        if let clause = specifiers?.throwsClause {
            guard clause.throwsSpecifier.text == "throws" else {
                try reject(fn, "Rethrows requires a callback-derived error and is not implemented")
            }
            if let failureType = clause.type {
                guard let type = failureType.as(IdentifierTypeSyntax.self),
                      type.genericArgumentClause == nil, simple(type.name.text),
                      !["Self", "Stubs", "Verification"].contains(type.name.text) else {
                    try reject(fn, "Use a named error type; complex error types are not implemented")
                }
                failure = type.name.text == "Never" ? .never : .typed(type.name.text)
            } else {
                failure = .ordinary
            }
        }
        if isolation == .mainActor {
            switch (isAsync, failure) {
            case (false, nil), (true, .typed?): break
            default: try reject(fn, "MainActor profile currently supports synchronous nonthrowing and async typed-throwing methods")
            }
        }
        let effect = Effect(isAsync: isAsync, failure: failure)
        let name = fn.name.text
        let label = parameter.firstName.text
        let descriptor = "\(name)(\(label):\(inputType))"
        guard descriptors.insert(descriptor).inserted else {
            try reject(fn, "Overloads that differ only by effects or result type require separate descriptor names")
        }
        let identity = "schema1|\(module).\(selected)|\(descriptor)\(effect.declaration)->\(outputType)|\(isolation.identity)"
        members.append(Member(name: name, label: label, inputType: inputType, outputType: outputType,
                              effect: effect, identity: identity,
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
        guard let failure = m.effect.runtimeFailure else { continue }
        output += "                failureMapping\(i): (\(failureIsolation) (MockIssue) -> \(failure.type))? = nil,\n"
    }
    output += "                _ configure: \(isolation.annotation)(Stubs) -> Void) {\n"
    for (i,m) in members.enumerated() {
        output += "        let setup\(i) = \(m.family)Stubbing<\(m.arguments)>()\n"
    }
    output += "        configure(Stubs(" + members.indices.map { "__setup\($0): setup\($0)" }.joined(separator: ", ") + "))\n"
    for (i,m) in members.enumerated() {
        var mapping = ""
        if let failure = m.effect.runtimeFailure {
            mapping = ", failureMapping: failureMapping\(i)"
            if failure.isOrdinary {
                mapping += " ?? { BlueprintMocking.UnexpectedInvocationError(issue: $0) }"
            }
        } else if m.outputType == "Void" {
            mapping = ", fallback: { _ in () }"
        }
        output += "        self.__endpoint\(i) = \(m.family)Endpoint(id: EndpointID(\(String(reflecting: m.identity))),\n            configuration: setup\(i).finish(), failureReporter: failureReporter\(mapping))\n"
    }
    output += "    }\n"
    for (i,m) in members.enumerated() {
        let file = module + "/" + URL(fileURLWithPath: input).lastPathComponent
        output += "\n    public func \(m.signature) {\n        \(m.effect.callPrefix)__endpoint\(i).invoke(input, source: SourceLocation(fileID: \(String(reflecting: file)), filePath: \(String(reflecting: URL(fileURLWithPath: input).lastPathComponent)), line: \(m.line), column: 1))\n    }\n"
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
