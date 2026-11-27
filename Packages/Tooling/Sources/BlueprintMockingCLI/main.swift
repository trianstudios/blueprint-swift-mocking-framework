import Foundation
import SwiftParser
import SwiftSyntax

struct GenerationError: Error, CustomStringConvertible {
    let description: String
}

struct ExplicitSourceConditions {
    private(set) var values: [String: [String: Bool]] = [:]

    mutating func read(from arguments: inout ArraySlice<String>) throws {
        guard let module = arguments.popFirst(), let flag = arguments.popFirst(),
              let value = arguments.popFirst(),
              ProtocolSourceIndex.isConditionIdentifier(module), ProtocolSourceIndex.isConditionIdentifier(flag),
              value == "true" || value == "false" else {
            throw GenerationError(description: "error: BPM002: Expected --source-condition MODULE FLAG true|false")
        }
        guard values[module]?[flag] == nil else {
            throw GenerationError(description: "error: BPM002: Duplicate source condition '\(flag)' for module '\(module)'")
        }
        values[module, default: [:]][flag] = value == "true"
    }
}
private struct MacOSIntroduction: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(attributes: AttributeListSyntax) {
        guard attributes.count == 1,
              let attribute = attributes.first?.as(AttributeSyntax.self),
              attribute.attributeName.trimmedDescription == "available",
              case .availability(let arguments)? = attribute.arguments,
              arguments.count == 2,
              case .availabilityVersionRestriction(let restriction)? = arguments.first?.argument,
              restriction.platform.text == "macOS", let version = restriction.version,
              case .token(let wildcard)? = arguments.last?.argument, wildcard.text == "*" else {
            return nil
        }
        let components = version.trimmedDescription.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { component -> Int? in
            guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            return Int(component)
        }
        guard (1...3).contains(components.count), numbers.count == components.count else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var annotation: String {
        let version = patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        return "@available(macOS \(version), *)\n"
    }
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
struct CallbackType {
    enum Kind {
        case scoped
        case escaping
        case mainActorEscaping
        case throwingEscaping(String)
        case asyncEscaping
        case asyncThrowingEscaping(String)
        case mainActorAsyncEscaping
        case mainActorThrowingEscaping(String)
        case mainActorAsyncThrowingEscaping(String)

        var family: String {
            switch self {
            case .scoped: "SyncCallback"
            case .escaping: "SyncEscapingCallback"
            case .mainActorEscaping: "SyncMainActorEscapingCallback"
            case .throwingEscaping: "SyncThrowingEscapingCallback"
            case .asyncEscaping: "SyncAsyncEscapingCallback"
            case .asyncThrowingEscaping: "SyncAsyncThrowingEscapingCallback"
            case .mainActorAsyncEscaping: "SyncMainActorAsyncEscapingCallback"
            case .mainActorThrowingEscaping: "SyncMainActorThrowingEscapingCallback"
            case .mainActorAsyncThrowingEscaping: "SyncMainActorAsyncThrowingEscapingCallback"
            }
        }

        var attributes: String {
            switch self {
            case .scoped: ""
            case .escaping, .throwingEscaping, .asyncEscaping, .asyncThrowingEscaping: "@escaping @Sendable "
            case .mainActorEscaping, .mainActorAsyncEscaping,
                 .mainActorThrowingEscaping, .mainActorAsyncThrowingEscaping:
                "@escaping @Swift.MainActor @Sendable "
            }
        }
    }

    let input: String
    let output: String
    let kind: Kind

    var failure: String? {
        switch kind {
        case .throwingEscaping(let failure), .asyncThrowingEscaping(let failure),
             .mainActorThrowingEscaping(let failure), .mainActorAsyncThrowingEscaping(let failure):
            failure
        default: nil
        }
    }

    var declaration: String {
        let effects: String
        switch kind {
        case .asyncEscaping, .mainActorAsyncEscaping: effects = " async"
        case .throwingEscaping(let failure), .mainActorThrowingEscaping(let failure): effects = " throws(\(failure))"
        case .asyncThrowingEscaping(let failure), .mainActorAsyncThrowingEscaping(let failure):
            effects = " async throws(\(failure))"
        default: effects = ""
        }
        return "\(kind.attributes)(\(input))\(effects) -> \(output)"
    }
}

struct Parameter {
    let label: String
    let type: String
    let isVariadic: Bool
    let isInout: Bool
    let callback: CallbackType?

    init(label: String, type: String, isVariadic: Bool = false, isInout: Bool = false,
         callback: CallbackType? = nil) {
        self.label = label
        self.type = type
        self.isVariadic = isVariadic
        self.isInout = isInout
        self.callback = callback
    }

    var witnessType: String {
        if isInout { return "inout \(type)" }
        return isVariadic ? "\(type)..." : type
    }
    var runtimeType: String { isVariadic ? "[\(type)]" : type }
}
struct GenericSubscript {
    let label: String
    let constraints: [String]
    let outputType: String
    let usesGenericResult: Bool
    let origin: ProtocolSourceOrigin

    var selector: String { "get_subscript(\(label):)" }

    var genericClause: String {
        constraints.isEmpty ? "<__BlueprintKey>" : "<__BlueprintKey: \(constraints.joined(separator: " & "))>"
    }

    var endpoint: String {
        let constraintClause = constraints.isEmpty ? "T" : "T:" + constraints.joined(separator: "&")
        return "subscript<\(constraintClause)>(\(label):T).get"
    }

    var resultIdentity: String { usesGenericResult ? "T" : outputType }
}

enum WitnessKind {
    case method
    case getter(String)
    case setter(String)
    case subscriptGetter(String)
    case subscriptSetter(String)
    case typeSubscriptGetter(String)
    case typeSubscriptSetter(String)
    case specializedSubscriptGetter(GenericSubscript, String)
}
struct Member {
    let name: String
    let parameters: [Parameter]
    let outputType: String
    let effect: Effect
    let identity: String
    let origin: ProtocolSourceOrigin
    let isolation: Isolation
    let kind: WitnessKind

    var usesInout: Bool { parameters.contains(where: \.isInout) }
    var callback: CallbackType? { parameters.last?.callback }
    var metadataParameters: [Parameter] { callback == nil ? parameters : Array(parameters.dropLast()) }
    var family: String {
        if let callback { return callback.kind.family }
        return (usesInout ? "Inout" : isolation.prefix) + effect.family
    }
    var verificationInputType: String { usesInout ? "InoutValues<\(inputType)>" : inputType }

    var isTypeLevel: Bool {
        switch kind {
        case .typeSubscriptGetter, .typeSubscriptSetter: true
        default: false
        }
    }

    var selector: String {
        "\(name)(" + parameters.map { "\($0.label):" }.joined() + ")"
    }

    var inputType: String {
        let metadata = metadataParameters
        if metadata.isEmpty { return "Void" }
        if metadata.count == 1 { return metadata[0].runtimeType }
        return "(" + metadata.map(\.runtimeType).joined(separator: ", ") + ")"
    }

    var genericArguments: String {
        if let callback {
            let arguments = "\(inputType), \(callback.input), \(callback.output), \(outputType)"
            return callback.failure.map { "\(arguments), \($0)" } ?? arguments
        }
        let types = "\(inputType), \(outputType)"
        return effect.runtimeFailure.map { "\(types), \($0.type)" } ?? types
    }

    private func argumentName(_ index: Int) -> String {
        parameters.count == 1 ? "input" : "input\(index)"
    }

    private func matcherName(_ index: Int) -> String {
        metadataParameters.count == 1 ? "matcher" : "matcher\(index)"
    }

    var parameterDeclaration: String {
        parameters.enumerated().map { index, parameter in
            "\(parameter.label) \(argumentName(index)): \(parameter.witnessType)"
        }.joined(separator: ", ")
    }

    var signature: String {
        "\(name)(\(parameterDeclaration))\(effect.declaration) -> \(outputType)"
    }

    var invocationArguments: [String] { parameters.indices.map(argumentName) }

    var invocationInput: String {
        let arguments = invocationArguments
        if usesInout { return "&" + arguments[0] }
        let metadata = callback == nil ? arguments[...] : arguments.dropLast()
        let inputs = metadata.count == 1 ? metadata[metadata.startIndex] : "(" + metadata.joined(separator: ", ") + ")"
        if callback != nil, let scoped = arguments.last { return "\(inputs), \(scoped)" }
        return inputs
    }

    private var descriptorParameters: [String] {
        var declarations = metadataParameters.enumerated().map { index, parameter in
            "\(parameter.label) \(matcherName(index)): \(isolation.prefix)Matcher<\(parameter.runtimeType)>"
        }
        if case .specializedSubscriptGetter(_, let type) = kind {
            declarations.append("as _: (\(type)).Type")
        }
        return declarations
    }

    var descriptorSignature: String {
        "\(name)(\(descriptorParameters.joined(separator: ", ")))"
    }

    func verificationSignature(includeOrigin: Bool = false) -> String {
        var descriptor = descriptorParameters
        if usesInout { descriptor.append("after: Matcher<\(inputType)>? = nil") }
        descriptor.append("phase: CallPhase = .admitted")
        if includeOrigin { descriptor.append("origin: CallOrigin? = nil") }
        return "\(name)(\(descriptor.joined(separator: ", ")))"
    }

    func matcherExpression(describingFields: Bool = false) -> String {
        let metadata = metadataParameters
        if metadata.isEmpty { return ".any" }
        if metadata.count == 1 { return matcherName(0) }
        let matches = metadata.indices.map { "\(matcherName($0)).matches(input.\($0))" }
            .joined(separator: " && ")
        let matcherType = "\(isolation.prefix)Matcher<\(inputType)>"
        if describingFields {
            let fields = metadata.enumerated().map { index, parameter in
                "(\(String(reflecting: parameter.label)), \(matcherName(index)).description)"
            }.joined(separator: ", ")
            return "BlueprintMocking.\(matcherType).matchingFields([\(fields)]) { input in \(matches) }"
        }
        return "\(matcherType) { input in \(matches) }"
    }
}

struct GeneratedProtocolMock {
    let typeName: String
    let source: String
    let associatedTypeBindings: [AssociatedTypeBinding]
}

func generate(
    index: ProtocolSourceIndex, root: IndexedProtocol, projections: [String], variadicForwarding: [String],
    subscriptSpecializations: [String], spy: Bool, associatedTypeBindings: [AssociatedTypeBinding] = []
) throws -> GeneratedProtocolMock {
    let input = root.origin.path
    let module = root.origin.module
    let selected = root.name
    let proto = root.declaration
    func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
        let origin = index.origin(of: node)
        throw GenerationError(description: "\(origin): error: BPM001: \(message)")
    }
    func simple(_ name: String) -> Bool {
        !name.isEmpty && name.first!.isLetter &&
        name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
    guard simple(module), simple(selected), proto.genericWhereClause == nil, proto.modifiers.map({ $0.name.text }) == ["public"] else {
        try reject(proto, "Select a top-level, non-generic public protocol")
    }
    let conformances = proto.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
    let isolation: Isolation
    let inheritance: ResolvedProtocolInheritance
    if proto.attributes.isEmpty {
        isolation = .sendable
        inheritance = try index.resolveSendable(from: root)
    } else if proto.attributes.count == 1,
              let attribute = proto.attributes.first?.as(AttributeSyntax.self),
              attribute.attributeName.trimmedDescription == "MainActor",
              attribute.leftParen == nil, attribute.arguments == nil,
              conformances.isEmpty {
        isolation = .mainActor
        inheritance = ResolvedProtocolInheritance(declarations: [root], parentsByDeclaration: [:], primaryTypeBindings: [])
    } else {
        try reject(proto, "Use a public Sendable protocol without attributes or a public @MainActor protocol without inheritance")
    }

    if spy {
        guard projections.isEmpty, variadicForwarding.isEmpty, subscriptSpecializations.isEmpty else {
            try reject(proto, "Direct spy forwarding cannot be combined with projections, variadic adapters or generic specializations")
        }
    }

    let activeMembers = try inheritance.declarations.map { declaration in
        (declarationID: declaration.declaration.id, items: try index.activeMembers(of: declaration))
    }
    let bindings = try ConcreteAssociatedTypeBindings(
        options: associatedTypeBindings, root: root, inheritance: inheritance, activeMembers: activeMembers, index: index)
    let hasBindings = !bindings.types.isEmpty
    if hasBindings && (spy || !projections.isEmpty || !variadicForwarding.isEmpty || !subscriptSpecializations.isEmpty) {
        try reject(proto, "Concrete associated-type bindings support ordinary witnesses without forwarding, projections or generic specializations")
    }
    let declarations = inheritance.declarations
    let hasImportedRequirements = declarations.contains { $0.origin.module != module }
    if hasImportedRequirements && (spy || !projections.isEmpty || !variadicForwarding.isEmpty || !subscriptSpecializations.isEmpty) {
        try reject(proto, "Supplied cross-module inheritance supports ordinary witnesses without forwarding, projections or generic specializations")
    }

    func importedType(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return bindings.boundType(for: identifier)
        }
        guard let qualified = type.as(MemberTypeSyntax.self), qualified.genericArgumentClause == nil,
              let qualifier = qualified.baseType.as(IdentifierTypeSyntax.self), qualifier.genericArgumentClause == nil,
              qualifier.name.text == "Swift", ["Bool", "Int", "String"].contains(qualified.name.text) else {
            return nil
        }
        return "Swift.\(qualified.name.text)"
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
        return bindings.resolve(identifier)
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
    var mockAvailability: MacOSIntroduction?
    var descriptors: [String: Member] = [:]
    var witnessesByName: [String: Member] = [:]
    var boundSelectors: [String: Member] = [:]
    func witnessName(_ name: String, kind: WitnessKind) -> String? {
        switch kind {
        case .method: name
        case .getter(let property), .setter(let property): property
        default: nil
        }
    }
    func addMember(
        name: String, parameters: [Parameter], outputType: String,
        effect: Effect, kind: WitnessKind, at node: some SyntaxProtocol
    ) throws {
        let source = index.origin(of: node)
        let witness = witnessName(name, kind: kind)
        if let witness, let previous = witnessesByName[witness],
           source.module != module || previous.origin.module != module {
            try reject(node, "A cross-module inherited requirement needs a distinct member name '\(witness)' "
                        + "(previous requirement at \(previous.origin))")
        }
        let parameterTypes = parameters.map { "\($0.label):\($0.witnessType)" }.joined(separator: ",")
        let matcherTypes = parameters.filter { $0.callback == nil }.map {
            "\($0.label):\($0.isInout ? "Int" : $0.runtimeType)"
        }.joined(separator: ",")
        let specialization: String
        if case .specializedSubscriptGetter(_, let type) = kind {
            specialization = ",as:\(type).Type"
        } else {
            specialization = ""
        }
        let namespace: String
        switch kind {
        case .typeSubscriptGetter, .typeSubscriptSetter: namespace = "type:"
        default: namespace = ""
        }
        let descriptor = "\(namespace)\(name)(\(matcherTypes)\(specialization))"
        if let previous = descriptors[descriptor] {
            let locations = " (previous requirement at \(previous.origin))"
            if parameters.contains(where: \.isVariadic) || previous.parameters.contains(where: \.isVariadic) {
                try reject(node, "Variadic overloads with identical lowered matcher signatures require distinct argument labels" + locations)
            }
            if parameters.contains(where: \.isInout) || previous.usesInout {
                try reject(node, "Inout overloads with identical matcher signatures require distinct argument labels" + locations)
            }
            if parameters.contains(where: { $0.callback != nil }) || previous.callback != nil {
                try reject(node, "Callback overloads with identical ordinary-argument matcher signatures require distinct argument labels" + locations)
            }
            try reject(node, "Overloads that differ only by effects or result type, or methods that collide with accessor descriptors, require separate descriptor names" + locations)
        }
        let endpoint: String
        var resultIdentity = outputType
        switch kind {
        case .method: endpoint = "\(name)(\(parameterTypes))"
        case .getter(let property): endpoint = "property:\(property).get"
        case .setter(let property): endpoint = "property:\(property).set(\(parameterTypes))"
        case .subscriptGetter(let indices): endpoint = "subscript:\(indices).get"
        case .subscriptSetter(let indices): endpoint = "subscript:\(indices).set(\(parameterTypes))"
        case .typeSubscriptGetter(let indices): endpoint = "type:subscript:\(indices).get"
        case .typeSubscriptSetter(let indices): endpoint = "type:subscript:\(indices).set(\(parameterTypes))"
        case .specializedSubscriptGetter(let declaration, _):
            endpoint = declaration.endpoint
            resultIdentity = declaration.resultIdentity
        }
        let identity = "schema1|\(module).\(selected)|\(endpoint)\(effect.declaration)->\(resultIdentity)|\(isolation.identity)"
        let member = Member(name: name, parameters: parameters, outputType: outputType,
                            effect: effect, identity: identity, origin: source,
                            isolation: isolation, kind: kind)
        if hasBindings {
            // Distinct type spellings can become the same Swift type after binding.
            let selector = member.selector
            if let previous = boundSelectors[selector] {
                try reject(node, "Concrete associated-type bindings need distinct argument labels for overloaded requirement '\(selector)' "
                           + "(previous requirement at \(previous.origin))")
            }
            boundSelectors[selector] = member
        }
        if let witness { witnessesByName[witness] = member }
        descriptors[descriptor] = member
        members.append(member)
    }

    func parseParameters(
        _ parameters: FunctionParameterListSyntax, forSubscript: Bool = false, imported: Bool = false
    ) throws -> [Parameter] {
        try parameters.map { parameter in
            // A single name on a subscript index is local. A method's is external.
            let label = forSubscript && parameter.secondName == nil ? "_" : parameter.firstName.text
            let isVariadic = parameter.ellipsis != nil
            let unmodified = parameter.attributes.isEmpty && parameter.modifiers.isEmpty &&
                parameter.defaultValue == nil && (simple(label) || label == "_")
            let tokens = parameter.type.tokens(viewMode: .sourceAccurate).map(\.text)
            if spy {
                if isVariadic {
                    try reject(parameter, "Direct spy call-through cannot splat a Swift variadic argument; use --forward-variadic with an array-taking provider")
                }
                if tokens.first == "inout" {
                    guard isolation == .sendable, !forSubscript, parameters.count == 1, unmodified,
                          let attributed = parameter.type.as(AttributedTypeSyntax.self),
                          attributed.attributes.isEmpty, attributed.specifiers.map(\.trimmedDescription) == ["inout"],
                          ["Int", "Swift.Int"].contains(attributed.baseType.trimmedDescription) else {
                        try reject(parameter, "Direct spy inout forwarding requires a Sendable method with one inout Swift.Int parameter")
                    }
                    return Parameter(label: label, type: "Swift.Int", isInout: true)
                }
                if tokens.contains("->") {
                    guard isolation == .sendable, !forSubscript, unmodified,
                          let function = parameter.type.as(FunctionTypeSyntax.self),
                          function.effectSpecifiers == nil, function.parameters.count == 1,
                          let input = function.parameters.first.flatMap({ supportedType($0.type) }),
                          let output = supportedResult(function.returnClause.type) else {
                        try reject(parameter, "Direct spy callbacks require one unannotated, nonescaping, synchronous nonthrowing function argument of supported value types")
                    }
                    let callback = CallbackType(input: input, output: output, kind: .scoped)
                    return Parameter(label: label, type: callback.declaration, callback: callback)
                }
            }
            if tokens.contains("->") {
                guard isolation == .sendable, !imported, !hasBindings, !forSubscript, !isVariadic, unmodified,
                      let attributed = parameter.type.as(AttributedTypeSyntax.self), attributed.specifiers.isEmpty,
                      let function = attributed.baseType.as(FunctionTypeSyntax.self),
                      function.parameters.count == 1, let argument = function.parameters.first, argument.inoutKeyword == nil,
                      argument.firstName == nil, argument.ellipsis == nil,
                      let input = supportedType(argument.type),
                      let output = supportedResult(function.returnClause.type) else {
                    try reject(parameter, "Escaping callback capture requires one function argument of supported value types")
                }
                let attributes = attributed.attributes.compactMap { element -> AttributeSyntax? in
                    guard let attribute = element.as(AttributeSyntax.self),
                          attribute.leftParen == nil, attribute.arguments == nil else { return nil }
                    return attribute
                }
                let names = Set(attributes.map { $0.attributeName.trimmedDescription })
                var kind: CallbackType.Kind
                switch names {
                case ["escaping", "Sendable"] where attributed.attributes.count == 2:
                    kind = .escaping
                case ["escaping", "Sendable", "MainActor"], ["escaping", "Sendable", "Swift.MainActor"]:
                    guard attributed.attributes.count == 3,
                          let actor = attributes.first(where: {
                              ["MainActor", "Swift.MainActor"].contains($0.attributeName.trimmedDescription)
                          }) else {
                        try reject(parameter, "Escaping callback capture requires exactly @escaping and @Sendable, optionally with @MainActor")
                    }
                    if actor.attributeName.trimmedDescription == "MainActor" {
                        try index.requireUnshadowedQualifier("MainActor", at: actor)
                    }
                    try index.requireUnshadowedQualifier("Swift", at: actor)
                    kind = .mainActorEscaping
                default:
                    try reject(parameter, "Escaping callback capture requires exactly @escaping and @Sendable, optionally with @MainActor")
                }
                if let effects = function.effectSpecifiers {
                    if let asyncSpecifier = effects.asyncSpecifier, asyncSpecifier.text != "async" {
                        try reject(parameter, "Escaping callback capture requires async for asynchronous function arguments")
                    }
                    let isAsync = effects.asyncSpecifier != nil
                    if let clause = effects.throwsClause {
                        guard clause.throwsSpecifier.text == "throws",
                              let failureType = clause.type?.as(IdentifierTypeSyntax.self),
                              failureType.genericArgumentClause == nil, simple(failureType.name.text),
                              !["Never", "Self", "Stubs", "Verification", selected + "Mock"].contains(failureType.name.text) else {
                            try reject(parameter, "Escaping callback capture requires throws with a named failure type other than Never")
                        }
                        let failure = failureType.name.text
                        if case .mainActorEscaping = kind {
                            kind = isAsync ? .mainActorAsyncThrowingEscaping(failure) : .mainActorThrowingEscaping(failure)
                        } else {
                            kind = isAsync ? .asyncThrowingEscaping(failure) : .throwingEscaping(failure)
                        }
                    } else if isAsync {
                        if case .mainActorEscaping = kind {
                            kind = .mainActorAsyncEscaping
                        } else {
                            kind = .asyncEscaping
                        }
                    }
                }
                let callback = CallbackType(input: input, output: output, kind: kind)
                return Parameter(label: label, type: callback.declaration, callback: callback)
            }
            if imported {
                guard let type = importedType(parameter.type), unmodified, !isVariadic else {
                    try reject(parameter, "Cross-module inherited parameters require an unmodified Swift.Bool, Swift.Int or Swift.String type, or a visible bound associated type")
                }
                return Parameter(label: label, type: type)
            }
            guard let type = supportedType(parameter.type), unmodified else {
                let subject = forSubscript ? "Subscript indices require" : "Use"
                try reject(parameter, "\(subject) named, optional, array or dictionary parameter types without ownership or default values")
            }
            return Parameter(label: label, type: type, isVariadic: isVariadic)
        }
    }

    func accessorModifiers(_ accessor: AccessorDeclSyntax) -> [String] {
        // SwiftSyntax 600 stores a single modifier; newer parsers use a list.
        accessor.children(viewMode: .sourceAccurate).flatMap { child -> [String] in
            if let modifier = child.as(DeclModifierSyntax.self) { return [modifier.name.text] }
            return child.as(DeclModifierListSyntax.self)?.map(\.name.text) ?? []
        }
    }

    func isNonmutatingSetter(_ accessor: AccessorDeclSyntax) -> Bool {
        accessor.accessorSpecifier.text == "set" && accessorModifiers(accessor) == ["nonmutating"]
    }

    func getterAndSetter(_ accessors: AccessorDeclListSyntax, at node: some SyntaxProtocol)
        throws -> (AccessorDeclSyntax, AccessorDeclSyntax?) {
        let setter = accessors.first(where: { $0.accessorSpecifier.text == "set" })
        guard accessors.allSatisfy({ $0.body == nil && $0.attributes.isEmpty && $0.parameters == nil
                                     && (accessorModifiers($0).isEmpty || isNonmutatingSetter($0)) }),
              let getter = accessors.first(where: { $0.accessorSpecifier.text == "get" }),
              accessors.count == (setter == nil ? 1 : 2) else {
            try reject(node, "Use an unmodified getter and an optional unmodified or nonmutating setter")
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
        if spy, let setter, !isNonmutatingSetter(setter) {
            try reject(setter, "Direct spy forwarding of a writable property requires a nonmutating setter or an explicit adapter")
        }
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

    var genericSubscripts: [(declaration: GenericSubscript, node: SubscriptDeclSyntax)] = []
    func collectGenericSubscript(
        _ decl: SubscriptDeclSyntax, indices: [Parameter], output: String,
        effect: Effect, setter: AccessorDeclSyntax?, getter: AccessorDeclSyntax
    ) throws {
        guard isolation == .sendable, setter == nil, !effect.isAsync, effect.failure == nil,
              decl.genericWhereClause == nil,
              let genericClause = decl.genericParameterClause, genericClause.parameters.count == 1,
              let key = genericClause.parameters.first, key.attributes.isEmpty,
              key.firstToken(viewMode: .sourceAccurate)?.id == key.name.id, simple(key.name.text),
              indices.count == 1, let keyParameter = indices.first,
              !keyParameter.isVariadic, keyParameter.type == key.name.text else {
            try reject(decl, "Generic specialization requires a synchronous read-only Sendable instance subscript with one generic index and inline constraints")
        }

        let constraintTypes = key.inheritedType.map { constraint -> [TypeSyntax] in
            if let composition = constraint.as(CompositionTypeSyntax.self) {
                return composition.elements.map(\.type)
            }
            return [constraint]
        } ?? []
        let constraints = try constraintTypes.map { constraint in
            guard let identifier = constraint.as(IdentifierTypeSyntax.self),
                  identifier.genericArgumentClause == nil, simple(identifier.name.text),
                  identifier.name.text != key.name.text else {
                try reject(constraint, "Use simple named inline generic constraints")
            }
            return identifier.name.text
        }.sorted()

        let usesGenericResult = output == key.name.text
        if !usesGenericResult && decl.returnClause.type.tokens(viewMode: .sourceAccurate)
            .contains(where: { $0.text == key.name.text }) {
            try reject(decl.returnClause, "Generic subscript results must be concrete or exactly the generic index type")
        }
        if output == "Void" {
            try reject(decl.returnClause, "Specialized generic subscripts require a value result")
        }
        let declaration = GenericSubscript(
            label: keyParameter.label, constraints: constraints, outputType: output, usesGenericResult: usesGenericResult,
            origin: index.origin(of: getter)
        )
        genericSubscripts.append((declaration, decl))
    }

    func addSubscript(_ decl: SubscriptDeclSyntax) throws {
        let isTypeLevel = decl.modifiers.map(\.name.text) == ["static"]
        guard decl.modifiers.isEmpty || isTypeLevel, decl.attributes.isEmpty,
              let output = supportedResult(decl.returnClause.type),
              let accessorBlock = decl.accessorBlock, case .accessors(let accessors) = accessorBlock.accessors else {
            try reject(decl, "Use an instance or static subscript with a supported result and explicit get and optional set accessors")
        }
        let indices = try parseParameters(decl.parameterClause.parameters, forSubscript: true)
        let (getter, setter) = try getterAndSetter(accessors, at: decl)
        if spy {
            guard !isTypeLevel else {
                try reject(decl, "Direct spy forwarding cannot dispatch static subscripts through an instance; use a metatype seam")
            }
            guard decl.genericParameterClause == nil, decl.genericWhereClause == nil else {
                try reject(decl, "Direct spy forwarding for a generic subscript requires a polymorphic provider")
            }
            if let setter, !isNonmutatingSetter(setter) {
                try reject(setter, "Direct spy forwarding of a writable subscript requires a nonmutating setter or an explicit adapter")
            }
        }
        let effects = getter.effectSpecifiers
        let effect = try methodEffect(effects?.asyncSpecifier, effects?.throwsClause, at: getter)
        if isTypeLevel {
            guard isolation == .sendable, !effect.isAsync, effect.failure == nil, setter?.effectSpecifiers == nil,
                  decl.genericParameterClause == nil, decl.genericWhereClause == nil, output != "Void",
                  !indices.contains(where: \.isVariadic) else {
                try reject(decl, "Type-level subscript scopes require a concrete synchronous Sendable static subscript with a value result")
            }
        }
        if decl.genericParameterClause != nil || decl.genericWhereClause != nil {
            try collectGenericSubscript(decl, indices: indices, output: output, effect: effect,
                                        setter: setter, getter: getter)
            return
        }
        if let setter, effect.isAsync || effect.failure != nil || setter.effectSpecifiers != nil {
            try reject(setter, "Effectful subscript getters require read-only subscripts; setters must be synchronous and nonthrowing")
        }
        let identity = "(" + indices.map { "\($0.label):\($0.witnessType)" }.joined(separator: ",") + ")"
        try addMember(name: "get_subscript", parameters: indices, outputType: output, effect: effect,
                      kind: isTypeLevel ? .typeSubscriptGetter(identity) : .subscriptGetter(identity), at: getter)
        if let setter {
            let parameters = indices + [Parameter(label: "newValue", type: output)]
            try addMember(name: "set_subscript", parameters: parameters, outputType: "Void",
                          effect: Effect(isAsync: false, failure: nil),
                          kind: isTypeLevel ? .typeSubscriptSetter(identity) : .subscriptSetter(identity), at: setter)
        }
    }

    for item in activeMembers.flatMap({ $0.items }) {
        if item.decl.is(AssociatedTypeDeclSyntax.self) { continue }
        if hasBindings && !item.decl.is(FunctionDeclSyntax.self) {
            try reject(item, "Concrete associated-type bindings currently support ordinary instance methods")
        }
        let source = index.origin(of: item)
        let imported = source.module != module
        if imported && !item.decl.is(FunctionDeclSyntax.self) {
            try reject(item, "Cross-module inherited requirements currently support simple instance methods")
        }
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
        guard fn.body == nil, fn.modifiers.isEmpty,
              fn.genericParameterClause == nil, fn.genericWhereClause == nil,
              simple(fn.name.text), !["init", "verify", "Stubs", "Verification"].contains(fn.name.text) else {
            try reject(fn, "Use a supported result type and a non-generic requirement without attributes or modifiers")
        }
        if hasBindings {
            if bindings.types[fn.name.text] != nil {
                try reject(fn, "A method name conflicts with its generated associated type alias")
            }
            if fn.signature.effectSpecifiers?.throwsClause?.type != nil {
                try reject(fn, "Concrete associated-type bindings do not yet support typed throws")
            }
        }
        let returnType = fn.signature.returnClause?.type
        if !fn.attributes.isEmpty {
            let hasAvailability = fn.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "available"
            }
            guard hasAvailability else {
                try reject(fn, "Use a supported result type and a non-generic requirement without attributes or modifiers")
            }
            guard let introduction = MacOSIntroduction(attributes: fn.attributes) else {
                try reject(fn, "Only @available(macOS VERSION, *) is supported on generated protocol methods")
            }
            guard isolation == .sendable, !imported, !hasBindings,
                  fn.signature.parameterClause.parameters.isEmpty, fn.signature.effectSpecifiers == nil,
                  let returnType, let identifier = returnType.as(IdentifierTypeSyntax.self),
                  supportedType(returnType) != nil else {
                try reject(fn, "A macOS availability requirement needs a synchronous, nonthrowing, parameterless Sendable"
                           + " instance method returning a same-module public struct")
            }
            let payload = try index.requireAvailabilityStruct(named: identifier.name.text, at: returnType)
            if !payload.attributes.isEmpty {
                guard let payloadIntroduction = MacOSIntroduction(attributes: payload.attributes) else {
                    try reject(payload, "Only @available(macOS VERSION, *) is supported on the result struct")
                }
                guard payloadIntroduction <= introduction else {
                    try reject(returnType, "The result struct is introduced after the protocol requirement")
                }
            }
            // Every generated signature and storage slot referring to the result lives in the class.
            mockAvailability = mockAvailability.map { max($0, introduction) } ?? introduction
        }
        let outputType: String
        if imported {
            try index.requireUnshadowedQualifier("Swift", at: fn)
            guard index.isUnshadowed("Swift", in: module) else {
                try reject(fn, "Cross-module inherited requirements need an unshadowed Swift module in the selected module")
            }
            if returnType == nil || fn.signature.parameterClause.parameters.isEmpty {
                guard index.isUnshadowed("Void", in: module) else {
                    try reject(fn, "Cross-module inherited witnesses with empty input or result need an unshadowed Void in the selected module")
                }
            }
            if let returnType {
                guard let resolved = importedType(returnType) else {
                    try reject(fn, "Cross-module inherited results require an explicit Swift.Bool, Swift.Int or Swift.String type, or a visible bound associated type")
                }
                outputType = resolved
            } else {
                outputType = "Void"
            }
        } else {
            guard let resolved = supportedResult(returnType) else {
                try reject(fn, "Use a supported result type and a non-generic requirement without attributes or modifiers")
            }
            outputType = resolved
        }
        let parameters = try parseParameters(fn.signature.parameterClause.parameters, imported: imported)
        let specifiers = fn.signature.effectSpecifiers
        if imported && specifiers?.throwsClause?.type != nil {
            try reject(fn, "Cross-module inherited methods support untyped throws; a typed error needs semantic type resolution")
        }
        let effect = try methodEffect(specifiers?.asyncSpecifier, specifiers?.throwsClause, at: fn)
        if imported && effect.failure?.isOrdinary == true && !index.isUnshadowed("Error", in: module) {
            try reject(fn, "Cross-module inherited throws needs an unshadowed Error in the selected module")
        }
        if effect.isAsync && parameters.contains(where: \.isInout) {
            try reject(fn, "Direct spy inout forwarding requires a synchronous method")
        }
        let callbacks = parameters.filter { $0.callback != nil }
        if !callbacks.isEmpty && (callbacks.count != 1 || parameters.last?.callback == nil ||
                                  effect.isAsync || effect.failure != nil) {
            try reject(fn, spy
                ? "Direct spy callbacks require a synchronous nonthrowing method with one callback in the final position"
                : "Escaping callback capture requires a synchronous nonthrowing Sendable method with one callback in the final position")
        }
        try addMember(name: fn.name.text, parameters: parameters, outputType: outputType,
                      effect: effect, kind: .method, at: fn)
    }
    var specializationTypes: [String: Set<String>] = [:]
    for option in subscriptSpecializations {
        let fields = option.split(separator: "=", maxSplits: 1)
        guard fields.count == 2 else {
            try reject(proto, "Use --specialize-subscript 'get_subscript(label:)=Type'")
        }
        let selector = fields[0].trimmingCharacters(in: .whitespaces)
        let candidates = genericSubscripts.filter { $0.declaration.selector == selector }
        guard let entry = candidates.first else {
            try reject(proto, "Unknown generic subscript selector '\(selector)'")
        }
        guard candidates.count == 1 else {
            try reject(entry.node, "Ambiguous generic subscript selector '\(selector)'; use distinct index labels")
        }
        let source = Parser.parse(source: "typealias BlueprintSpecialization = \(fields[1])")
        guard !source.hasError, source.statements.count == 1,
              let alias = source.statements.first?.item.as(TypeAliasDeclSyntax.self),
              let type = supportedType(alias.initializer.value) else {
            try reject(entry.node, "Unsupported generic subscript specialization type '\(fields[1])'")
        }
        guard specializationTypes[selector, default: []].insert(type).inserted else {
            try reject(entry.node, "Duplicate generic subscript specialization '\(type)' for '\(selector)'")
        }
    }
    for (declaration, node) in genericSubscripts {
        guard let types = specializationTypes[declaration.selector] else {
            try reject(node, "Generic subscripts require explicit specialization using --specialize-subscript '\(declaration.selector)=Type'")
        }
        for type in types.sorted() {
            try addMember(name: "get_subscript", parameters: [Parameter(label: declaration.label, type: type)],
                          outputType: declaration.usesGenericResult ? type : declaration.outputType,
                          effect: Effect(isAsync: false, failure: nil),
                          kind: .specializedSubscriptGetter(declaration, type), at: node)
        }
    }
    guard !members.isEmpty else { try reject(proto, "The selected protocol has no supported requirements") }
    members.sort { ($0.identity, $0.inputType) < ($1.identity, $1.inputType) }
    let typeIndices = members.indices.filter { members[$0].isTypeLevel }
    let instanceIndices = members.indices.filter { !members[$0].isTypeLevel }
    if !typeIndices.isEmpty && !projections.isEmpty {
        try reject(proto, "Type-level subscript scopes cannot be combined with generated projected mock types")
    }
    var setterIndices: [String: Int] = [:]
    var subscriptSetters: [String: Int] = [:]
    var typeSubscriptSetters: [String: Int] = [:]
    for (i, m) in members.enumerated() {
        if case .setter(let property) = m.kind { setterIndices[property] = i }
        if case .subscriptSetter(let indices) = m.kind { subscriptSetters[indices] = i }
        if case .typeSubscriptSetter(let indices) = m.kind { typeSubscriptSetters[indices] = i }
    }
    func selectMember(_ selector: String, purpose: String, includeSubscripts: Bool = false) throws -> Int {
        let matches = members.indices.filter {
            let member = members[$0]
            guard selector == member.selector || selector == member.identity else { return false }
            switch member.kind {
            case .method: return true
            case .subscriptGetter, .subscriptSetter: return includeSubscripts
            case .getter, .setter, .specializedSubscriptGetter, .typeSubscriptGetter, .typeSubscriptSetter:
                return false
            }
        }
        guard let index = matches.first else {
            let accessors = includeSubscripts ? " or subscript accessor" : ""
            try reject(proto, "Unknown \(purpose) selector '\(selector)'; use an instance method\(accessors) with its argument labels")
        }
        guard matches.count == 1 else {
            let choices = matches.map { members[$0].identity }.joined(separator: ", ")
            try reject(proto, "Ambiguous \(purpose) selector '\(selector)'; use one canonical endpoint ID: \(choices)")
        }
        return index
    }

    var projectedIndices = Set<Int>()
    for selector in projections {
        guard isolation == .sendable else {
            try reject(proto, "Generated projections require a Sendable protocol")
        }
        let index = try selectMember(selector, purpose: "projection")
        guard members[index].callback == nil else {
            try reject(proto, "Projection selector '\(selector)' cannot retain a callback requirement")
        }
        let family = members[index].effect.family
        guard family == "Sync" || family == "AsyncThrowing" else {
            try reject(proto, "Projection selector '\(selector)' requires a synchronous nonthrowing or async-throwing method")
        }
        guard projectedIndices.insert(index).inserted else {
            try reject(proto, "Duplicate projection selector for '\(members[index].selector)'")
        }
    }

    var forwardingIndices = Set<Int>()
    for selector in variadicForwarding {
        guard isolation == .sendable else {
            try reject(proto, "Generated variadic forwarding adapters require a Sendable protocol")
        }
        let index = try selectMember(selector, purpose: "variadic forwarding", includeSubscripts: true)
        let member = members[index]
        guard member.callback == nil else {
            try reject(proto, "Variadic forwarding selector '\(selector)' cannot forward a callback requirement")
        }
        guard member.parameters.contains(where: \.isVariadic) else {
            try reject(proto, "Variadic forwarding selector '\(selector)' requires a variadic instance method or subscript accessor")
        }
        guard forwardingIndices.insert(index).inserted else {
            try reject(proto, "Duplicate variadic forwarding selector for '\(member.selector)'")
        }
    }

    let name = selected + (projectedIndices.isEmpty ? "Mock" : "ProjectedMock")
    let memberTypeNames = Set(members.flatMap {
        $0.genericArguments.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
    })
    let usedNames = memberTypeNames.union([selected])
    let failureIndices = members.indices.filter { members[$0].effect.runtimeFailure != nil }
    if !failureIndices.isEmpty, memberTypeNames.contains("FailureMappings") {
        try reject(proto, "A requirement type collides with the generated 'FailureMappings' setup type")
    }
    if !forwardingIndices.isEmpty, memberTypeNames.contains("VariadicForwarding") {
        try reject(proto, "A requirement type collides with the generated 'VariadicForwarding' setup type")
    }
    if !typeIndices.isEmpty, !memberTypeNames.isDisjoint(with: ["TypeScope", "TypeStubs", "TypeVerification"]) {
        try reject(proto, "A requirement type collides with a generated type-level scope or descriptor type")
    }
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
    let linkedIndices = spy ? instanceIndices.filter { members[$0].family == "AsyncThrowing" } : []
    if !linkedIndices.isEmpty &&
        (!usedNames.isDisjoint(with: ["ForwardingLinks", "ForwardingTargets"]) ||
         members.contains(where: { member in
             switch member.kind {
             case .method: member.name == "forwardingTargets" && member.parameters.isEmpty
             case .getter(let name), .setter(let name): name == "forwardingTargets"
             default: false
             }
         })) {
        try reject(proto, "A requirement conflicts with generated forwarding link setup or target names")
    }
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

    \(mockAvailability?.annotation ?? "")\(isolation.annotation)public final class \(declaration): \(selected) {
        private let __schema: BlueprintMocking.BlueprintRuntimeSchemaV1.Type = BlueprintMocking.BlueprintRuntimeSchemaV1.self

    """
    let resolvedBindings = bindings.types.sorted { $0.key < $1.key }.map {
        AssociatedTypeBinding(name: $0.key, type: $0.value)
    }
    for binding in resolvedBindings {
        output += "    public typealias \(binding.name) = \(binding.type)\n"
    }
    let specializedEndpoints = Dictionary(grouping: members.indices.filter {
        if case .specializedSubscriptGetter = members[$0].kind { return true }
        return false
    }, by: { members[$0].identity })
    if !specializedEndpoints.isEmpty {
        output += "    private let __scope: MockScope\n    private let __failureReporter: FailureReporter\n"
    }
    for i in instanceIndices {
        output += "    private let __endpoint\(i): \(endpointType(i))\n"
    }
    output += "\n    \(isolation.annotation)public struct Stubs {\n"
    for i in instanceIndices {
        let m = members[i]
        output += "        fileprivate let __setup\(i): \(m.family)Stubbing<\(m.genericArguments)>\n"
        output += "        public func \(m.descriptorSignature) -> \(m.family)Stub<\(m.genericArguments)> {\n            __setup\(i).matching(\(m.matcherExpression()))\n        }\n"
    }
    for (i, m) in members.enumerated() {
        guard case .getter(let property) = m.kind, let setter = setterIndices[property] else { continue }
        output += "\n        public func store_\(property)(initialValue: \(m.outputType)) {\n"
        output += "            let cell = \(isolation.prefix)StoredProperty(initialValue)\n"
        output += "            __setup\(i).matching(.any).willAnswer { _ in cell.get() }\n"
        output += "            __setup\(setter).matching(.any).willAnswer { cell.set($0) }\n"
        output += "        }\n"
    }
    let isolationConformance = isolation == .sendable ? ": Sendable" : ""
    let failureIsolation = isolation == .sendable ? "@Sendable" : "@MainActor"
    output += "    }\n\n"
    if !failureIndices.isEmpty {
        output += "    \(isolation.annotation)public struct FailureMappings\(isolationConformance) {\n"
        output += "        public init(_ configure: \(isolation.annotation)(inout Self) -> Void = { _ in }) {\n"
        output += "            configure(&self)\n        }\n"
        for index in failureIndices {
            let member = members[index]
            let mapper = "\(failureIsolation) (MockIssue) -> \(member.effect.runtimeFailure!.type)"
            let selector = member.parameters.map { "\($0.label) _: (\($0.runtimeType)).Type" }
            let signature = (selector + ["_ mapping: @escaping \(mapper)"]).joined(separator: ", ")
            output += "        fileprivate var __mapping\(index): (\(mapper))? = nil\n"
            output += "        public mutating func \(member.name)(\(signature)) {\n"
            output += "            __mapping\(index) = mapping\n        }\n"
        }
        output += "    }\n\n"
    }
    if !linkedIndices.isEmpty {
        output += "    public struct ForwardingLinks: Sendable {\n"
        output += "        public init(_ configure: (inout Self) -> Void = { _ in }) {\n"
        output += "            configure(&self)\n        }\n"
        for index in linkedIndices {
            let member = members[index]
            let link = "AsyncThrowingForwardingLink<\(member.genericArguments)>"
            let selector = member.parameters.map { "\($0.label) _: (\($0.runtimeType)).Type" }
            let signature = (selector + ["through link: \(link)"]).joined(separator: ", ")
            output += "        fileprivate var __link\(index): \(link)? = nil\n"
            output += "        public mutating func \(member.name)(\(signature)) {\n"
            output += "            __link\(index) = link\n        }\n"
        }
        output += "    }\n\n"
        output += "    public struct ForwardingTargets: Sendable {\n"
        for index in linkedIndices {
            let member = members[index]
            let selector = member.parameters.map { "\($0.label) _: (\($0.runtimeType)).Type" }
            let signature = selector.joined(separator: ", ")
            output += "        fileprivate let __endpoint\(index): \(endpointType(index))\n"
            output += "        public func \(member.name)(\(signature)) -> AsyncThrowingForwardingTarget<\(member.genericArguments)> {\n"
            output += "            __endpoint\(index).forwardingTarget\n        }\n"
        }
        output += "    }\n\n    public var forwardingTargets: ForwardingTargets {\n        ForwardingTargets(" +
            linkedIndices.map { "__endpoint\($0): __endpoint\($0)" }.joined(separator: ", ") + ")\n    }\n\n"
    }
    if !forwardingIndices.isEmpty {
        output += "    public struct VariadicForwarding: Sendable {\n"
        output += "        public init(_ configure: (inout Self) -> Void = { _ in }) {\n"
        output += "            configure(&self)\n        }\n"
        for index in forwardingIndices.sorted() {
            let member = members[index]
            let parameters = member.parameters.map(\.runtimeType).joined(separator: ", ")
            let effects = (member.effect.isAsync ? " async" : "") +
                (member.effect.runtimeFailure.map { " throws(\($0.type))" } ?? "")
            let adapter = "@Sendable (\(parameters))\(effects) -> \(member.outputType)"
            let selector = member.parameters.map { "\($0.label) _: (\($0.runtimeType)).Type" }
            let signature = (selector + ["_ adapter: @escaping \(adapter)"]).joined(separator: ", ")
            let arguments = member.parameters.count == 1 ? "input"
                : member.parameters.indices.map { "input.\($0)" }.joined(separator: ", ")
            output += "        fileprivate var __install\(index): (@Sendable (\(member.family)Stubbing<\(member.genericArguments)>) -> Void)? = nil\n"
            output += "        public mutating func \(member.name)(\(signature)) {\n"
            output += "            __install\(index) = { setup in\n"
            output += "                setup.matching(.any).willAnswer { input\(effects) in\n"
            output += "                    \(member.effect.callPrefix)adapter(\(arguments))\n"
            output += "                }\n            }\n        }\n"
        }
        output += "    }\n\n"
    }
    output += "    \(isolation.annotation)public struct Verification\(isolationConformance) {\n"
    for i in instanceIndices {
        let m = members[i]
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
            let after = m.usesInout ? ", after: after" : ""
            let origin = spy ? ", origin: origin" : ""
            output += "        public func \(m.verificationSignature(includeOrigin: spy)) -> BlueprintMocking.\(isolation.prefix)Verification<\(m.verificationInputType)> {\n            __endpoint\(i).verification(matching: \(m.matcherExpression(describingFields: true))\(after), phase: phase\(origin))\n        }\n"
        }
    }
    output += "    }\n\n    public var verify: Verification {\n        Verification(" +
        instanceIndices.map { "__endpoint\($0): __endpoint\($0)" }.joined(separator: ", ") + ")\n    }\n\n"
    if !linkedIndices.isEmpty {
        output += """
            public convenience init(failureReporter: FailureReporter,
                        session: MockSession = MockSession(),
                        forwardingTo: (any \(selected))? = nil,
                        failureMappings: FailureMappings = .init(),
                        _ configure: (Stubs) -> Void) {
                self.init(failureReporter: failureReporter, session: session, forwardingTo: forwardingTo,
                          maximumAsyncThrowingForwardingDepth: nil, forwardingLinks: .init(),
                          failureMappings: failureMappings, configure)
            }

            public convenience init(failureReporter: FailureReporter,
                        session: MockSession = MockSession(),
                        forwardingTo: (any \(selected))? = nil,
                        maximumAsyncThrowingForwardingDepth: Int?,
                        failureMappings: FailureMappings = .init(),
                        _ configure: (Stubs) -> Void) {
                self.init(failureReporter: failureReporter, session: session, forwardingTo: forwardingTo,
                          maximumAsyncThrowingForwardingDepth: maximumAsyncThrowingForwardingDepth,
                          forwardingLinks: .init(), failureMappings: failureMappings, configure)
            }


        """
    }
    output += "    public init(failureReporter: FailureReporter,\n"
    if isolation == .sendable { output += "                session: MockSession = MockSession(),\n" }
    if spy { output += "                forwardingTo: (any \(selected))? = nil,\n" }
    if !linkedIndices.isEmpty {
        output += "                maximumAsyncThrowingForwardingDepth: Int? = nil,\n"
        output += "                forwardingLinks: ForwardingLinks,\n"
    }
    if !failureIndices.isEmpty {
        output += "                failureMappings: FailureMappings = .init(),\n"
    }
    if !forwardingIndices.isEmpty {
        output += "                forwarding: VariadicForwarding = .init(),\n"
    }
    for i in projectedIndices.sorted() {
        let member = members[i]
        let types = projectionTypes[i]!
        output += "                projection\(i): InvocationProjection<\(member.inputType), \(member.outputType), \(types.argument), \(types.result)>,\n"
    }
    output += "                _ configure: \(isolation.annotation)(Stubs) -> Void) {\n"
    if isolation == .sendable && !instanceIndices.isEmpty {
        output += "        let scope = session.makeMock()\n"
    }
    if !specializedEndpoints.isEmpty {
        output += "        self.__scope = scope\n        self.__failureReporter = failureReporter\n"
    }
    for i in instanceIndices {
        let m = members[i]
        output += "        let setup\(i) = \(m.family)Stubbing<\(m.genericArguments)>()\n"
    }
    for i in forwardingIndices.sorted() {
        output += "        forwarding.__install\(i)?(setup\(i))\n"
    }
    output += "        configure(Stubs(" + instanceIndices.map { "__setup\($0): setup\($0)" }.joined(separator: ", ") + "))\n"
    func spyForwardingArgument(_ index: Int) -> String {
        let member = members[index]
        func inputExpression(_ index: Int) -> String {
            member.metadataParameters.count == 1 ? "input" : "input.\(index)"
        }
        let arguments = member.parameters.enumerated().map { index, parameter in
            let value = parameter.callback != nil ? "callback" :
                (parameter.isInout ? "&" : "") + inputExpression(index)
            return parameter.label == "_" ? value : "\(parameter.label): \(value)"
        }
        let call: String
        switch member.kind {
        case .method:
            call = "target.\(member.name)(\(arguments.joined(separator: ", ")))"
        case .getter(let property):
            call = "target.\(property)"
        case .setter(let property):
            call = "target.\(property) = input"
        case .subscriptGetter:
            call = "target[\(arguments.joined(separator: ", "))]"
        case .subscriptSetter:
            let indices = arguments.dropLast().joined(separator: ", ")
            call = "target[\(indices)] = \(inputExpression(member.parameters.count - 1))"
        default:
            preconditionFailure("The spy profile filters unsupported witnesses before emission")
        }
        let input: String
        if member.usesInout {
            input = "(input: inout \(member.inputType))"
        } else {
            let ordinaryInput = member.metadataParameters.isEmpty ? "_" : "input"
            input = member.callback == nil ? ordinaryInput : "\(ordinaryInput), callback"
        }
        let isolationAttribute = isolation == .sendable ? "@Sendable" : "@MainActor"
        let effects = (member.effect.isAsync ? " async" : "") +
            (member.effect.runtimeFailure.map { " throws(\($0.type))" } ?? "")
        let wrapper: String
        if member.effect.runtimeFailure == nil {
            wrapper = ""
        } else {
            let depth = member.family == "AsyncThrowing" ? "(maximumDepth: maximumAsyncThrowingForwardingDepth)" : ""
            wrapper = "\(member.family)Forwarding<\(member.genericArguments)>\(depth) "
        }
        let link = member.family == "AsyncThrowing"
            ? "forwardingLinks.__link\(index).map { AsyncThrowingForwarding(link: $0) } ?? " : ""
        return ", forwarding: \(link)forwardingTo.map { target in\n                \(wrapper){ \(isolationAttribute) \(input)\(effects) in \(member.effect.callPrefix)\(call) }\n            }"
    }

    for i in instanceIndices {
        let m = members[i]
        var mapping = isolation == .sendable ? ", scope: scope" : ""
        if spy { mapping += spyForwardingArgument(i) }
        if let failure = m.effect.runtimeFailure {
            mapping += ", failureMapping: failureMappings.__mapping\(i)"
            if failure.isOrdinary {
                mapping += " ?? { BlueprintMocking.UnexpectedInvocationError(issue: $0) }"
            }
        } else if m.outputType == "Void" {
            mapping += ", fallback: { _ in () }"
        }
        let projection = projectedIndices.contains(i) ? ", projection: projection\(i)" : ""
        let identity = String(reflecting: m.identity)
        var endpointID = "EndpointID(\(identity))"
        if case .specializedSubscriptGetter(let declaration, let type) = m.kind {
            endpointID = "EndpointID(\(identity), specializedFor: (\(type)).self)"
            if !declaration.constraints.isEmpty, let first = specializedEndpoints[m.identity]?.first {
                output += "        Self.__validateSpecialization\(first)((\(type)).self)\n"
            }
        }
        output += "        self.__endpoint\(i) = \(endpointFamily(i))Endpoint(id: \(endpointID),\n            configuration: setup\(i).finish()\(projection), failureReporter: failureReporter\(mapping))\n"
    }
    output += "    }\n"
    if !typeIndices.isEmpty {
        output += "\n    @TaskLocal private static var __typeScope: TypeScope?\n"
        output += "\n    public struct TypeStubs {\n"
        for i in typeIndices {
            let member = members[i]
            output += "        fileprivate let __setup\(i): SyncStubbing<\(member.genericArguments)>\n"
            output += "        public func \(member.descriptorSignature) -> SyncStub<\(member.genericArguments)> {\n            __setup\(i).matching(\(member.matcherExpression()))\n        }\n"
        }
        output += "    }\n\n    public struct TypeVerification: Sendable {\n"
        for i in typeIndices {
            let member = members[i]
            output += "        fileprivate let __endpoint\(i): \(endpointType(i))\n"
            output += "        public func \(member.verificationSignature()) -> BlueprintMocking.Verification<\(member.inputType)> {\n            __endpoint\(i).verification(matching: \(member.matcherExpression(describingFields: true)), phase: phase)\n        }\n"
        }
        output += "    }\n\n"
        output += """
            public struct TypeScope: Sendable {
        """
        output += "\n"
        for i in typeIndices {
            output += "        fileprivate let __endpoint\(i): \(endpointType(i))\n"
        }
        output += "        public var verify: TypeVerification {\n            TypeVerification(" +
            typeIndices.map { "__endpoint\($0): __endpoint\($0)" }.joined(separator: ", ") + ")\n        }\n"
        output += """

                public func withValue<Value>(_ body: () throws -> Value) rethrows -> Value {
                    try \(name).$__typeScope.withValue(self, operation: body)
                }

                public func withValue<Value, Failure: Error>(
                    isolation: isolated (any Actor)? = #isolation,
                    _ body: () async throws(Failure) -> Value
                ) async throws(Failure) -> Value {
                    #if compiler(>=6.2)
                    let operation: nonisolated(nonsending) () async -> Result<Value, Failure> = {
                        do throws(Failure) { return .success(try await body()) }
                        catch { return .failure(error) }
                    }
                    let result = await \(name).$__typeScope.withValue(self, operation: operation)
                    #else
                    let result: Result<Value, Failure> = await \(name).$__typeScope.withValue(
                        self, operation: {
                            do throws(Failure) { return .success(try await body()) }
                            catch { return .failure(error) }
                        }, isolation: isolation
                    )
                    #endif
                    return try result.get()
                }
            }

            public static func makeTypeScope(
                failureReporter: FailureReporter,
                session: MockSession = MockSession(),
                _ configure: (TypeStubs) -> Void
            ) -> TypeScope {
                let scope = session.makeEpochBoundMock()
        """
        output += "\n"
        for i in typeIndices {
            output += "        let setup\(i) = SyncStubbing<\(members[i].genericArguments)>()\n"
        }
        output += "        configure(TypeStubs(" +
            typeIndices.map { "__setup\($0): setup\($0)" }.joined(separator: ", ") + "))\n"
        for i in typeIndices {
            let member = members[i]
            let fallback = member.outputType == "Void" ? ", fallback: { _ in () }" : ""
            output += "        let endpoint\(i) = \(endpointFamily(i))Endpoint(id: EndpointID(\(String(reflecting: member.identity))),\n"
            output += "            configuration: setup\(i).finish(), failureReporter: failureReporter, scope: scope\(fallback))\n"
        }
        output += "        return TypeScope(" +
            typeIndices.map { "__endpoint\($0): endpoint\($0)" }.joined(separator: ", ") + ")\n    }\n"
    }
    func location(_ origin: ProtocolSourceOrigin) -> String {
        let fileID = origin.module + "/" + origin.fileName
        return "SourceLocation(fileID: \(String(reflecting: fileID)), filePath: \(String(reflecting: origin.fileName)), line: \(origin.line), column: 1)"
    }
    func call(_ index: Int, _ argument: String, origin: ProtocolSourceOrigin? = nil) -> String {
        let member = members[index]
        return "\(member.effect.callPrefix)__endpoint\(index).invoke(\(argument), source: \(location(origin ?? member.origin)))"
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
        case .specializedSubscriptGetter(let declaration, _):
            let indices = specializedEndpoints[m.identity]!
            guard indices.first == i else { continue }
            if !declaration.constraints.isEmpty {
                output += "\n    private static func __validateSpecialization\(i)\(declaration.genericClause)(_: __BlueprintKey.Type) {}\n"
            }
            let result = declaration.usesGenericResult ? "__BlueprintKey" : declaration.outputType
            output += "\n    public subscript\(declaration.genericClause)(\(declaration.label) input: __BlueprintKey) -> \(result) {\n"
            for index in indices {
                let type = members[index].inputType
                output += "        if __BlueprintKey.self == (\(type)).self, let key = input as? \(type) {\n"
                if declaration.usesGenericResult {
                    output += "            let value = \(call(index, "key", origin: declaration.origin))\n"
                    output += "            guard let result = value as? __BlueprintKey else { preconditionFailure(\"Mismatched subscript specialization result\") }\n"
                    output += "            return result\n"
                } else {
                    output += "            return \(call(index, "key", origin: declaration.origin))\n"
                }
                output += "        }\n"
            }
            output += "        __scope.terminateMissingSpecialization(of: \(String(reflecting: m.identity)), for: __BlueprintKey.self,\n"
            output += "            reporter: __failureReporter, source: \(location(declaration.origin)))\n    }\n"
        case .typeSubscriptGetter(let indices):
            func missingScope(_ member: Member) -> String {
                "BlueprintMocking.BlueprintRuntimeSchemaV1.reportMissingTypeScope(EndpointID(\(String(reflecting: member.identity))), source: \(location(member.origin)))"
            }
            output += "\n    public static subscript(\(m.parameterDeclaration)) -> \(m.outputType) {\n"
            output += "        get {\n            guard let scope = __typeScope else {\n"
            output += "                fatalError(\(missingScope(m)))\n            }\n"
            output += "            return scope.\(call(i, m.invocationInput))\n        }\n"
            if let setter = typeSubscriptSetters[indices] {
                let arguments = "(" + (m.invocationArguments + ["newValue"]).joined(separator: ", ") + ")"
                output += "        set {\n            guard let scope = __typeScope else {\n"
                output += "                _ = \(missingScope(members[setter]))\n                return\n            }\n"
                output += "            scope.\(call(setter, arguments))\n        }\n"
            }
            output += "    }\n"
        case .setter, .subscriptSetter, .typeSubscriptSetter:
            continue
        }
    }
    return GeneratedProtocolMock(typeName: name, source: output + "}\n", associatedTypeBindings: resolvedBindings)
}

private func run(_ arguments: [String]) throws {
    if arguments.first == "inspect" {
        try inspectBuildOutputs(arguments: arguments.dropFirst())
        return
    }
    if arguments.first == "verify-generated" {
        try verifyBuildOutputs(arguments: arguments.dropFirst())
        return
    }
    if arguments.first == "generate" && arguments.dropFirst().first == "--config" {
        try generateBuildOutputs(arguments: arguments.dropFirst())
        return
    }
    let arguments = arguments.first == "generate" ? Array(arguments.dropFirst()) : arguments
    let usage = GenerationError(description: "usage: generate --input source.swift --module Module --protocol Protocol --output Mock.swift [--project 'method(label:)']... [--forward-variadic 'member(label:)']... [--specialize-subscript 'get_subscript(label:)=Type']... [--spy] [--source MODULE FILE]... [--bind-associated-type 'Name=Type']... [--source-condition MODULE FLAG true|false]...")
    guard arguments.count >= 8, arguments[0] == "--input", arguments[2] == "--module",
          arguments[4] == "--protocol", arguments[6] == "--output" else { throw usage }
    var options = arguments.dropFirst(8)
    var projections: [String] = []
    var variadicForwarding: [String] = []
    var subscriptSpecializations: [String] = []
    var bindingArguments: [String] = []
    var spy = false
    var sourcePaths: [String: [String]] = [:]
    var sourceConditions = ExplicitSourceConditions()
    while let flag = options.popFirst() {
        switch flag {
        case "--spy":
            guard !spy else { throw usage }
            spy = true
        case "--source":
            guard let module = options.popFirst(), let path = options.popFirst() else { throw usage }
            sourcePaths[module, default: []].append(path)
        case "--source-condition":
            try sourceConditions.read(from: &options)
        case "--project":
            guard let selector = options.popFirst() else { throw usage }
            projections.append(selector)
        case "--forward-variadic":
            guard let selector = options.popFirst() else { throw usage }
            variadicForwarding.append(selector)
        case "--specialize-subscript":
            guard let specialization = options.popFirst() else { throw usage }
            subscriptSpecializations.append(specialization)
        case "--bind-associated-type":
            guard let binding = options.popFirst() else { throw usage }
            bindingArguments.append(binding)
        default: throw usage
        }
    }
    let input = arguments[1]
    let module = arguments[3]
    sourcePaths[module, default: []].append(input)
    let index = ProtocolSourceIndex(sources: sourcePaths, conditions: sourceConditions.values)
    let root = try index.select(arguments[5], in: module, diagnosticFile: input)
    guard URL(fileURLWithPath: root.origin.path).standardizedFileURL == URL(fileURLWithPath: input).standardizedFileURL else {
        throw GenerationError(description: "\(input):1:1: error: BPM001: The selected protocol must be declared in --input")
    }
    let associatedTypeBindings = try bindingArguments.map { argument in
        guard let binding = AssociatedTypeBinding(argument: argument) else {
            throw GenerationError(description: "\(root.origin): error: BPM001: Use --bind-associated-type 'Name=Type'")
        }
        return binding
    }
    let output = try generate(index: index, root: root, projections: projections,
                              variadicForwarding: variadicForwarding,
                              subscriptSpecializations: subscriptSpecializations, spy: spy,
                              associatedTypeBindings: associatedTypeBindings)
    // Parsing and validation finish before publication. No partial output on unsupported input.
    try output.source.write(toFile: arguments[7], atomically: true, encoding: .utf8)
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch let mismatch as GeneratedOutputMismatch {
    FileHandle.standardError.write(Data("\(mismatch)\n".utf8))
    exit(3)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
