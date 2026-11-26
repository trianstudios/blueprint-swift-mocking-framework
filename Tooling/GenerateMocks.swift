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
struct Parameter {
    let label: String
    let type: String
}
enum WitnessKind {
    case method
    case getter(String)
    case setter(String)
    case subscriptGetter(String)
    case subscriptSetter(String)
}
struct Member {
    let name: String
    let parameters: [Parameter]
    let outputType: String
    let effect: Effect
    let identity: String
    let line: Int
    let isolation: Isolation
    let kind: WitnessKind

    var family: String { isolation.prefix + effect.family }

    var projectionSelector: String {
        "\(name)(" + parameters.map { "\($0.label):" }.joined() + ")"
    }

    var inputType: String {
        if parameters.isEmpty { return "Void" }
        if parameters.count == 1 { return parameters[0].type }
        return "(" + parameters.map(\.type).joined(separator: ", ") + ")"
    }

    var genericArguments: String {
        let types = "\(inputType), \(outputType)"
        return effect.runtimeFailure.map { "\(types), \($0.type)" } ?? types
    }

    private func argumentName(_ index: Int) -> String {
        parameters.count == 1 ? "input" : "input\(index)"
    }

    private func matcherName(_ index: Int) -> String {
        parameters.count == 1 ? "matcher" : "matcher\(index)"
    }

    var parameterDeclaration: String {
        parameters.enumerated().map { index, parameter in
            "\(parameter.label) \(argumentName(index)): \(parameter.type)"
        }.joined(separator: ", ")
    }

    var signature: String {
        "\(name)(\(parameterDeclaration))\(effect.declaration) -> \(outputType)"
    }

    var invocationArguments: [String] { parameters.indices.map(argumentName) }

    var invocationInput: String {
        let arguments = invocationArguments
        if arguments.count == 1 { return arguments[0] }
        return "(" + arguments.joined(separator: ", ") + ")"
    }

    private var descriptorParameters: [String] {
        parameters.enumerated().map { index, parameter in
            "\(parameter.label) \(matcherName(index)): \(isolation.prefix)Matcher<\(parameter.type)>"
        }
    }

    var descriptorSignature: String {
        "\(name)(\(descriptorParameters.joined(separator: ", ")))"
    }

    var verificationSignature: String {
        let descriptor = descriptorParameters + ["phase: CallPhase = .admitted"]
        return "\(name)(\(descriptor.joined(separator: ", ")))"
    }

    var matcherExpression: String {
        if parameters.isEmpty { return ".any" }
        if parameters.count == 1 { return matcherName(0) }
        let matches = parameters.indices.map { "\(matcherName($0)).matches(input.\($0))" }
            .joined(separator: " && ")
        return "\(isolation.prefix)Matcher<\(inputType)> { input in \(matches) }"
    }
}

func generate(input: String, module: String, selected: String, projections: [String]) throws -> String {
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
        if let optional = type.as(OptionalTypeSyntax.self) {
            return supportedType(optional.wrappedType).map { "\($0)?" }
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return supportedType(array.element).map { "[\($0)]" }
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self),
           let key = supportedType(dictionary.key), let value = supportedType(dictionary.value) {
            return "[\(key): \(value)]"
        }
        guard let identifier = type.as(IdentifierTypeSyntax.self),
              identifier.genericArgumentClause == nil,
              simple(identifier.name.text),
              !["Self", "Never", "Void", "Stubs", "Verification", selected + "Mock"].contains(identifier.name.text) else {
            return nil
        }
        return identifier.name.text
    }
    func supportedResult(_ type: TypeSyntax?) -> String? {
        guard let type else { return "Void" }
        if type.trimmedDescription == "Void" || type.as(TupleTypeSyntax.self)?.elements.isEmpty == true {
            return "Void"
        }
        if type.trimmedDescription == "Never" { return "Never" }
        return supportedType(type)
    }
    func methodEffect(
        _ asyncSpecifier: TokenSyntax?, _ throwsClause: ThrowsClauseSyntax?, at node: some SyntaxProtocol
    ) throws -> Effect {
        if let asyncSpecifier, asyncSpecifier.text != "async" {
            try reject(node, "Only async method effects are supported")
        }
        let isAsync = asyncSpecifier != nil
        var failure: FailureEffect?
        if let clause = throwsClause {
            guard clause.throwsSpecifier.text == "throws" else {
                try reject(node, "Rethrows requires a callback-derived error and is not implemented")
            }
            if let failureType = clause.type {
                guard let type = failureType.as(IdentifierTypeSyntax.self),
                      type.genericArgumentClause == nil, simple(type.name.text),
                      !["Self", "Stubs", "Verification"].contains(type.name.text) else {
                    try reject(node, "Use a named error type; complex error types are not implemented")
                }
                failure = type.name.text == "Never" ? .never : .typed(type.name.text)
            } else {
                failure = .ordinary
            }
        }
        return Effect(isAsync: isAsync, failure: failure)
    }

    var members: [Member] = []
    var descriptors = Set<String>()
    func addMember(
        name: String, parameters: [Parameter], outputType: String,
        effect: Effect, kind: WitnessKind, at node: some SyntaxProtocol
    ) throws {
        let parameterTypes = parameters.map { "\($0.label):\($0.type)" }.joined(separator: ",")
        let descriptor = "\(name)(\(parameterTypes))"
        guard descriptors.insert(descriptor).inserted else {
            try reject(node, "Overloads that differ only by effects or result type, or methods that collide with accessor descriptors, require separate descriptor names")
        }
        let endpoint: String
        switch kind {
        case .method: endpoint = descriptor
        case .getter(let property): endpoint = "property:\(property).get"
        case .setter(let property): endpoint = "property:\(property).set(\(parameterTypes))"
        case .subscriptGetter(let indices): endpoint = "subscript:\(indices).get"
        case .subscriptSetter(let indices): endpoint = "subscript:\(indices).set(\(parameterTypes))"
        }
        let identity = "schema1|\(module).\(selected)|\(endpoint)\(effect.declaration)->\(outputType)|\(isolation.identity)"
        members.append(Member(name: name, parameters: parameters, outputType: outputType,
                              effect: effect, identity: identity,
                              line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                              isolation: isolation, kind: kind))
    }

    func parseParameters(
        _ parameters: FunctionParameterListSyntax, forSubscript: Bool = false
    ) throws -> [Parameter] {
        try parameters.map { parameter in
            // A single name on a subscript index is local. A method's is external.
            let label = forSubscript && parameter.secondName == nil ? "_" : parameter.firstName.text
            guard let type = supportedType(parameter.type),
                  parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
                  parameter.ellipsis == nil, parameter.defaultValue == nil,
                  simple(label) || label == "_" else {
                let subject = forSubscript ? "Subscript indices require" : "Use"
                try reject(parameter, "\(subject) named, optional, array or dictionary parameter types without ownership, variadics or default values")
            }
            return Parameter(label: label, type: type)
        }
    }

    func getterAndSetter(_ accessors: AccessorDeclListSyntax, at node: some SyntaxProtocol)
        throws -> (AccessorDeclSyntax, AccessorDeclSyntax?) {
        let setter = accessors.first(where: { $0.accessorSpecifier.text == "set" })
        guard accessors.allSatisfy({ $0.body == nil && $0.attributes.isEmpty && $0.modifiers.isEmpty
                                     && $0.parameters == nil }),
              let getter = accessors.first(where: { $0.accessorSpecifier.text == "get" }),
              accessors.count == (setter == nil ? 1 : 2) else {
            try reject(node, "Only unmodified get and optional set accessors are supported")
        }
        return (getter, setter)
    }

    func addProperty(_ property: VariableDeclSyntax) throws {
        guard property.bindingSpecifier.text == "var", property.modifiers.isEmpty,
              property.attributes.isEmpty, property.bindings.count == 1,
              let binding = property.bindings.first, binding.initializer == nil,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              simple(name), !["verify", "Stubs", "Verification"].contains(name),
              let declaredType = binding.typeAnnotation?.type, let type = supportedResult(declaredType),
              let accessorBlock = binding.accessorBlock,
              case .accessors(let accessors) = accessorBlock.accessors else {
            try reject(property, "Use a public protocol property with a supported type and explicit get and optional set accessors")
        }
        let (getter, setter) = try getterAndSetter(accessors, at: property)
        let getterEffects = getter.effectSpecifiers
        let effect = try methodEffect(getterEffects?.asyncSpecifier, getterEffects?.throwsClause, at: getter)
        if let setter, effect.isAsync || effect.failure != nil || setter.effectSpecifiers != nil {
            try reject(setter, "Effectful getters require read-only properties; setters must be synchronous and nonthrowing")
        }
        try addMember(name: "get_\(name)", parameters: [], outputType: type,
                      effect: effect, kind: .getter(name), at: getter)
        if let setter {
            try addMember(name: "set_\(name)", parameters: [Parameter(label: "_", type: type)],
                          outputType: "Void", effect: Effect(isAsync: false, failure: nil),
                          kind: .setter(name), at: setter)
        }
    }

    func addSubscript(_ decl: SubscriptDeclSyntax) throws {
        guard decl.genericParameterClause == nil, decl.genericWhereClause == nil else {
            try reject(decl, "Generic subscripts require explicit specialization support")
        }
        guard !decl.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else {
            try reject(decl, "Static and class subscripts require a scoped type-level adapter")
        }
        guard decl.modifiers.isEmpty, decl.attributes.isEmpty,
              let output = supportedResult(decl.returnClause.type),
              let accessorBlock = decl.accessorBlock, case .accessors(let accessors) = accessorBlock.accessors else {
            try reject(decl, "Use an unmodified instance subscript with a supported result and explicit get and optional set accessors")
        }
        let indices = try parseParameters(decl.parameterClause.parameters, forSubscript: true)
        let (getter, setter) = try getterAndSetter(accessors, at: decl)
        let effects = getter.effectSpecifiers
        let effect = try methodEffect(effects?.asyncSpecifier, effects?.throwsClause, at: getter)
        if let setter, effect.isAsync || effect.failure != nil || setter.effectSpecifiers != nil {
            try reject(setter, "Effectful subscript getters require read-only subscripts; setters must be synchronous and nonthrowing")
        }
        let identity = "(" + indices.map { "\($0.label):\($0.type)" }.joined(separator: ",") + ")"
        try addMember(name: "get_subscript", parameters: indices, outputType: output, effect: effect,
                      kind: .subscriptGetter(identity), at: getter)
        if let setter {
            let parameters = indices + [Parameter(label: "newValue", type: output)]
            try addMember(name: "set_subscript", parameters: parameters, outputType: "Void",
                          effect: Effect(isAsync: false, failure: nil), kind: .subscriptSetter(identity), at: setter)
        }
    }

    for item in proto.memberBlock.members {
        if let decl = item.decl.as(SubscriptDeclSyntax.self) {
            try addSubscript(decl)
            continue
        }
        if let property = item.decl.as(VariableDeclSyntax.self) {
            try addProperty(property)
            continue
        }
        guard let fn = item.decl.as(FunctionDeclSyntax.self) else {
            try reject(item, "Only function, property and instance subscript requirements are supported in this slice")
        }
        guard fn.body == nil, fn.attributes.isEmpty, fn.modifiers.isEmpty,
              fn.genericParameterClause == nil, fn.genericWhereClause == nil,
              simple(fn.name.text), !["init", "verify", "Stubs", "Verification"].contains(fn.name.text),
              let outputType = supportedResult(fn.signature.returnClause?.type) else {
            try reject(fn, "Use a supported result type and a non-generic requirement without attributes or modifiers")
        }
        let parameters = try parseParameters(fn.signature.parameterClause.parameters)
        let specifiers = fn.signature.effectSpecifiers
        let effect = try methodEffect(specifiers?.asyncSpecifier, specifiers?.throwsClause, at: fn)
        try addMember(name: fn.name.text, parameters: parameters, outputType: outputType,
                      effect: effect, kind: .method, at: fn)
    }
    guard !members.isEmpty else { try reject(proto, "The selected protocol has no supported requirements") }
    members.sort { $0.identity < $1.identity }
    var setterIndices: [String: Int] = [:]
    var subscriptSetters: [String: Int] = [:]
    for (i, m) in members.enumerated() {
        if case .setter(let property) = m.kind { setterIndices[property] = i }
        if case .subscriptSetter(let indices) = m.kind { subscriptSetters[indices] = i }
    }
    var projectedIndices = Set<Int>()
    for selector in projections {
        guard isolation == .sendable else {
            try reject(proto, "Generated projections require a Sendable protocol")
        }
        let matches = members.indices.filter {
            let member = members[$0]
            guard case .method = member.kind else { return false }
            return selector == member.projectionSelector || selector == member.identity
        }
        guard let index = matches.first else {
            try reject(proto, "Unknown projection selector '\(selector)'; use a method with its argument labels")
        }
        guard matches.count == 1 else {
            let choices = matches.map { members[$0].identity }.joined(separator: ", ")
            try reject(proto, "Ambiguous projection selector '\(selector)'; use one canonical endpoint ID: \(choices)")
        }
        let family = members[index].effect.family
        guard family == "Sync" || family == "AsyncThrowing" else {
            try reject(proto, "Projection selector '\(selector)' requires a synchronous nonthrowing or async-throwing method")
        }
        guard projectedIndices.insert(index).inserted else {
            try reject(proto, "Duplicate projection selector for '\(members[index].projectionSelector)'")
        }
    }

    let name = selected + (projectedIndices.isEmpty ? "Mock" : "ProjectedMock")
    let usedNames = Set(members.flatMap {
        $0.genericArguments.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
    } + [selected])
    if !projectedIndices.isEmpty, usedNames.contains(name) {
        try reject(proto, "A method type collides with the generated projected mock name '\(name)'")
    }
    func projectionType(_ name: String) -> String {
        var candidate = name
        while usedNames.contains(candidate) { candidate += "_" }
        return candidate
    }

    var projectionTypes: [Int: (argument: String, result: String)] = [:]
    for index in projectedIndices.sorted() {
        let historyNames = ["history\(index)", "stableHistory\(index)"]
        if let collision = members.indices.first(where: {
            !projectedIndices.contains($0) && historyNames.contains(members[$0].name)
        }) {
            try reject(proto, "An existing verification member collides with generated '\(members[collision].name)'")
        }
        projectionTypes[index] = (
            projectionType("ProjectionArgument\(index)"), projectionType("ProjectionResult\(index)")
        )
    }
    let genericTypes = projectedIndices.sorted().flatMap { index in
        let types = projectionTypes[index]!
        return ["\(types.argument): Sendable", "\(types.result): Sendable"]
    }
    let declaration = genericTypes.isEmpty ? name : name + "<" + genericTypes.joined(separator: ", ") + ">"
    func endpointFamily(_ index: Int) -> String {
        let family = members[index].family
        return projectedIndices.contains(index) ? "Projected" + family : family
    }
    func endpointType(_ index: Int) -> String {
        var arguments = members[index].genericArguments
        if let types = projectionTypes[index] {
            arguments += ", \(types.argument), \(types.result)"
        }
        return "\(endpointFamily(index))Endpoint<\(arguments)>"
    }
    var output = """
    // Generated by the Blueprint Mocking prototype. Schema 1. Do not edit.
    // Source: \(URL(fileURLWithPath: input).lastPathComponent), protocol \(selected).
    // \((isolation == .sendable ? "Sendable nominal types" : "MainActor nominal types")) profile; consumer compilation is the conformance gate.
    import BlueprintMocking
    import \(module)

    \(isolation.annotation)public final class \(declaration): \(selected) {
        private let __schema: BlueprintRuntimeSchemaV1.Type = BlueprintRuntimeSchemaV1.self

    """
    for i in members.indices {
        output += "    private let __endpoint\(i): \(endpointType(i))\n"
    }
    output += "\n    \(isolation.annotation)public struct Stubs {\n"
    for (i,m) in members.enumerated() {
        output += "        fileprivate let __setup\(i): \(m.family)Stubbing<\(m.genericArguments)>\n"
        output += "        public func \(m.descriptorSignature) -> \(m.family)Stub<\(m.genericArguments)> {\n            __setup\(i).matching(\(m.matcherExpression))\n        }\n"
    }
    for (i, m) in members.enumerated() {
        guard case .getter(let property) = m.kind, let setter = setterIndices[property] else { continue }
        output += "\n        public func store_\(property)(initialValue: \(m.outputType)) {\n"
        output += "            let cell = \(isolation.prefix)StoredProperty(initialValue)\n"
        output += "            __setup\(i).matching(.any).willAnswer { _ in cell.get() }\n"
        output += "            __setup\(setter).matching(.any).willAnswer { cell.set($0) }\n"
        output += "        }\n"
    }
    let verificationConformance = isolation == .sendable ? ": Sendable" : ""
    output += "    }\n\n    \(isolation.annotation)public struct Verification\(verificationConformance) {\n"
    for (i,m) in members.enumerated() {
        output += "        fileprivate let __endpoint\(i): \(endpointType(i))\n"
        if let types = projectionTypes[i] {
            output += "        public var history\(i): ProjectedInvocationHistory<\(types.argument), \(types.result)> {\n            __endpoint\(i).projectedHistory()\n        }\n"
            for (label, type) in [("matchingArgument", types.argument), ("matchingResult", types.result)] {
                output += """
                        public func stableHistory\(i)(
                            _ count: BlueprintMocking.CallCount, \(label) value: Swift.String,
                            for duration: Swift.Duration, within timeout: Swift.Duration
                        ) async throws -> BlueprintMocking.SessionTimedCountObservation where \(type) == Swift.String {
                            try await __endpoint\(i).stable(count, \(label): value, for: duration, within: timeout)
                        }

                """
            }
        } else {
            output += "        public func \(m.verificationSignature) -> BlueprintMocking.\(isolation.prefix)Verification<\(m.inputType)> {\n            __endpoint\(i).verification(matching: \(m.matcherExpression), phase: phase)\n        }\n"
        }
    }
    output += "    }\n\n    public var verify: Verification {\n        Verification(" +
        members.indices.map { "__endpoint\($0): __endpoint\($0)" }.joined(separator: ", ") + ")\n    }\n\n"
    output += "    public init(failureReporter: FailureReporter,\n"
    if isolation == .sendable { output += "                session: MockSession = MockSession(),\n" }
    let failureIsolation = isolation == .sendable ? "@Sendable" : "@MainActor"
    for (i,m) in members.enumerated() {
        guard let failure = m.effect.runtimeFailure else { continue }
        output += "                failureMapping\(i): (\(failureIsolation) (MockIssue) -> \(failure.type))? = nil,\n"
    }
    for i in projectedIndices.sorted() {
        let member = members[i]
        let types = projectionTypes[i]!
        output += "                projection\(i): InvocationProjection<\(member.inputType), \(member.outputType), \(types.argument), \(types.result)>,\n"
    }
    output += "                _ configure: \(isolation.annotation)(Stubs) -> Void) {\n"
    if isolation == .sendable { output += "        let scope = session.makeMock()\n" }
    for (i,m) in members.enumerated() {
        output += "        let setup\(i) = \(m.family)Stubbing<\(m.genericArguments)>()\n"
    }
    output += "        configure(Stubs(" + members.indices.map { "__setup\($0): setup\($0)" }.joined(separator: ", ") + "))\n"
    for (i,m) in members.enumerated() {
        var mapping = isolation == .sendable ? ", scope: scope" : ""
        if let failure = m.effect.runtimeFailure {
            mapping += ", failureMapping: failureMapping\(i)"
            if failure.isOrdinary {
                mapping += " ?? { BlueprintMocking.UnexpectedInvocationError(issue: $0) }"
            }
        } else if m.outputType == "Void" {
            mapping += ", fallback: { _ in () }"
        }
        let projection = projectedIndices.contains(i) ? ", projection: projection\(i)" : ""
        output += "        self.__endpoint\(i) = \(endpointFamily(i))Endpoint(id: EndpointID(\(String(reflecting: m.identity))),\n            configuration: setup\(i).finish()\(projection), failureReporter: failureReporter\(mapping))\n"
    }
    output += "    }\n"
    let fileName = URL(fileURLWithPath: input).lastPathComponent
    let fileID = module + "/" + fileName
    func call(_ index: Int, _ argument: String) -> String {
        let member = members[index]
        return "\(member.effect.callPrefix)__endpoint\(index).invoke(\(argument), source: SourceLocation(fileID: \(String(reflecting: fileID)), filePath: \(String(reflecting: fileName)), line: \(member.line), column: 1))"
    }
    for (i, m) in members.enumerated() {
        switch m.kind {
        case .method:
            output += "\n    public func \(m.signature) {\n        \(call(i, m.invocationInput))\n    }\n"
        case .getter(let property):
            output += "\n    public var \(property): \(m.outputType) {\n"
            output += "        get\(m.effect.declaration) {\n            \(call(i, "()"))\n        }\n"
            if let setter = setterIndices[property] {
                output += "        set {\n            \(call(setter, "newValue"))\n        }\n"
            }
            output += "    }\n"
        case .subscriptGetter(let indices):
            output += "\n    public subscript(\(m.parameterDeclaration)) -> \(m.outputType) {\n"
            output += "        get\(m.effect.declaration) {\n            \(call(i, m.invocationInput))\n        }\n"
            if let setter = subscriptSetters[indices] {
                let arguments = "(" + (m.invocationArguments + ["newValue"]).joined(separator: ", ") + ")"
                output += "        set {\n            \(call(setter, arguments))\n        }\n"
            }
            output += "    }\n"
        case .setter, .subscriptSetter:
            continue
        }
    }
    return output + "}\n"
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 8, arguments.count.isMultiple(of: 2), arguments[0] == "--input",
          arguments[2] == "--module", arguments[4] == "--protocol", arguments[6] == "--output",
          stride(from: 8, to: arguments.count, by: 2).allSatisfy({ arguments[$0] == "--project" }) else {
        throw GenerationError(description: "usage: generate --input source.swift --module Module --protocol Protocol --output Mock.swift [--project 'method(label:)']...")
    }
    let projections = stride(from: 9, to: arguments.count, by: 2).map { arguments[$0] }
    let output = try generate(input: arguments[1], module: arguments[3], selected: arguments[5],
                              projections: projections)
    // Parsing and validation finish before publication. No partial output on unsupported input.
    try output.write(toFile: arguments[7], atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
