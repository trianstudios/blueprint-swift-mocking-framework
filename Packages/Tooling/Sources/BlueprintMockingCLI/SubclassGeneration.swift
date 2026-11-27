import Foundation
import SwiftParser
import SwiftSyntax

struct SubclassGenerationRequest {
    let input: String
    let module: String
    let name: String
    let selector: String
    let output: String

    init(arguments: ArraySlice<String>) throws {
        let values = Array(arguments)
        guard values.count == 10, values[0] == "--input", values[2] == "--module",
              values[4] == "--class", values[6] == "--override", values[8] == "--output",
              ProtocolSourceIndex.isConditionIdentifier(values[3]),
              ProtocolSourceIndex.isConditionIdentifier(values[5]),
              !["Swift", "BlueprintMocking"].contains(values[3]),
              !Parser.parse(source: "import \(values[3])").hasError else {
            throw GenerationError(description:
                "usage: subclass --input Source.swift --module Module --class Class --override 'method(_:)' --output Mock.swift")
        }
        input = values[1]
        module = values[3]
        name = values[5]
        selector = values[7]
        output = values[9]
    }
}

private struct SubclassInterface {
    let module: String
    let name: String
    let method: String
    let methodLabel: String
    let initializerLabel: String
    let sourceFile: String
    let line: Int
    let column: Int
}

func generateSubclass(_ request: SubclassGenerationRequest) throws -> String {
    let input = try String(contentsOfFile: request.input, encoding: .utf8)
    return renderSubclass(try subclassInterface(request, source: input))
}

private func subclassInterface(_ request: SubclassGenerationRequest, source: String) throws -> SubclassInterface {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: request.input, tree: tree)
    func diagnose(_ token: TokenSyntax, _ message: String) -> GenerationError {
        let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return GenerationError(description: "\(request.input):\(location.line):\(location.column): error: BPM001: \(message)")
    }
    let firstToken = tree.firstToken(viewMode: .sourceAccurate) ?? tree.endOfFileToken
    guard !tree.hasError else { throw diagnose(firstToken, "subclass input contains syntax errors") }
    guard tree.statements.count == 1,
          let type = tree.statements.first?.item.as(ClassDeclSyntax.self),
          type.name.text == request.name else {
        throw diagnose(firstToken, "subclass input must contain exactly the selected top-level class")
    }
    let modifiers = type.modifiers.map { $0.name.text }
    if modifiers.contains("final") {
        throw diagnose(type.classKeyword, "cannot subclass a final class; inject a protocol adapter")
    }
    guard modifiers == ["open"] else {
        throw diagnose(type.classKeyword, "cross-module subclass generation requires an open class; inject a protocol adapter")
    }
    guard type.name.text != request.module, !["Swift", "BlueprintMocking"].contains(type.name.text),
          type.genericParameterClause == nil, type.genericWhereClause == nil, type.inheritanceClause == nil,
          type.attributes.count == 1,
          let actor = type.attributes.first?.as(AttributeSyntax.self),
          actor.attributeName.trimmedDescription == "Swift.MainActor", actor.arguments == nil else {
        throw diagnose(type.classKeyword, "subclass generation requires a non-generic @Swift.MainActor root class")
    }

    let members = type.memberBlock.members
    let reserved: Set<String> = ["Stubs", "Verification", "verify", "__blueprintEndpoint",
                                 "__blueprintCallSuper", "__BlueprintSchema", "Swift", "BlueprintMocking", request.module]
    for member in members {
        if let function = member.decl.as(FunctionDeclSyntax.self) {
            guard !reserved.contains(function.name.text) else {
                throw diagnose(function.name, "class member collides with generated subclass controls")
            }
        } else if let property = member.decl.as(VariableDeclSyntax.self) {
            for binding in property.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self),
                      !reserved.contains(name.identifier.text) else {
                    throw diagnose(property.bindingSpecifier, "class property collides with generated subclass controls")
                }
            }
        } else if let deinitializer = member.decl.as(DeinitializerDeclSyntax.self) {
            throw diagnose(deinitializer.deinitKeyword, "explicit deinitializer is unsupported for subclass generation")
        } else if !member.decl.is(InitializerDeclSyntax.self) {
            throw diagnose(type.classKeyword, "subclass inputs support only initializers, methods and properties")
        }
    }

    let initializers = members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }
    guard initializers.count == 1, let initializer = initializers.first else {
        throw diagnose(type.classKeyword, "subclass generation requires one explicit designated initializer")
    }
    let initializerModifiers = initializer.modifiers.map { $0.name.text }
    if initializerModifiers.contains("required") {
        throw diagnose(initializer.initKeyword, "required initializer is unsupported; inject a protocol adapter")
    }
    guard initializerModifiers == ["public"], initializer.body != nil else {
        throw diagnose(initializer.initKeyword, "requires an accessible public designated initializer; inject a protocol adapter")
    }
    guard initializer.attributes.isEmpty, initializer.optionalMark == nil, initializer.genericParameterClause == nil,
          initializer.genericWhereClause == nil, initializer.signature.effectSpecifiers == nil,
          let initializerLabel = subclassScalarLabel(initializer.signature.parameterClause.parameters),
          !["failureReporter", "configure"].contains(initializerLabel) else {
        throw diagnose(initializer.initKeyword, "expected a synchronous nonthrowing designated initializer with one Swift.String")
    }

    let methods = members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }.filter { function in
        let labels = function.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
        return "\(function.name.text)(\(labels))" == request.selector
    }
    guard methods.count == 1, let method = methods.first else {
        throw diagnose(type.classKeyword, "override selector must select exactly one directly declared method")
    }
    let methodModifiers = method.modifiers.map { $0.name.text }
    if methodModifiers.contains("private") || methodModifiers.contains("fileprivate") {
        throw diagnose(method.funcKeyword,
                       "selected private or fileprivate method is unavailable for direct replacement. "
                           + "Expose an adapter in its owning scope or use an accessible enclosing operation.")
    }
    guard methodModifiers == ["open"], method.body != nil else {
        throw diagnose(method.funcKeyword, "selected override must be open and overridable across modules; inject a protocol adapter")
    }
    guard method.attributes.isEmpty, method.genericParameterClause == nil, method.genericWhereClause == nil,
          method.signature.effectSpecifiers == nil,
          ProtocolSourceIndex.isConditionIdentifier(method.name.text),
          let methodLabel = subclassScalarLabel(method.signature.parameterClause.parameters),
          !["phase", "origin"].contains(methodLabel),
          method.signature.returnClause?.type.trimmedDescription == "Swift.String" else {
        throw diagnose(method.funcKeyword, "expected a synchronous nonthrowing open method taking and returning Swift.String")
    }

    let position = converter.location(for: method.funcKeyword.positionAfterSkippingLeadingTrivia)
    return SubclassInterface(module: request.module, name: request.name, method: method.name.text,
                             methodLabel: methodLabel, initializerLabel: initializerLabel,
                             sourceFile: URL(fileURLWithPath: request.input).lastPathComponent,
                             line: position.line, column: position.column)
}

private func subclassScalarLabel(_ parameters: FunctionParameterListSyntax) -> String? {
    guard parameters.count == 1, let parameter = parameters.first, parameter.defaultValue == nil,
          parameter.ellipsis == nil, parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
          parameter.type.trimmedDescription == "Swift.String",
          parameter.firstName.text == "_" || ProtocolSourceIndex.isConditionIdentifier(parameter.firstName.text) else {
        return nil
    }
    return parameter.firstName.text
}

private func renderSubclass(_ interface: SubclassInterface) -> String {
    func declaration(_ label: String, local: String) -> String {
        label == local ? label : "\(label) \(local)"
    }
    func argument(_ label: String, local: String) -> String {
        label == "_" ? local : "\(label): \(local)"
    }
    let base = "\(interface.module).\(interface.name)"
    let method = interface.method
    let initParameter = declaration(interface.initializerLabel, local: "seed")
    let superInitializer = argument(interface.initializerLabel, local: "seed")
    let methodParameter = declaration(interface.methodLabel, local: "input")
    let matcherParameter = declaration(interface.methodLabel, local: "matcher")
    let superArgument = argument(interface.methodLabel, local: "input")
    let type = "Swift.String"
    let endpoint = "BlueprintMocking.MainActorSyncEndpoint<\(type), \(type)>"
    let stubbing = "BlueprintMocking.MainActorSyncStubbing<\(type), \(type)>"
    let matcher = "BlueprintMocking.MainActorMatcher<\(type)>"
    let identity = "schema\(GeneratedContract.irSchemaVersion)|\(base)|\(method)(\(interface.methodLabel):Swift.String)->Swift.String|MainActor"
    let marker = GeneratedContract.runtimeMarker
    let fileID = String(reflecting: "\(interface.module)/\(interface.sourceFile)")
    let path = String(reflecting: interface.sourceFile)
    let location = "BlueprintMocking.SourceLocation(fileID: \(fileID), staticFilePath: \(path), line: \(interface.line), column: \(interface.column))"
    return """
    // Generated by Blueprint Mocking.
    import BlueprintMocking
    import \(interface.module)

    @Swift.MainActor
    public final class \(interface.name)Mock: \(base) {
        private typealias __BlueprintSchema = \(marker)
        private var __blueprintEndpoint: \(endpoint)?

        @Swift.MainActor
        public struct Stubs {
            fileprivate let endpoint: \(stubbing)
            public func \(method)(\(matcherParameter): \(matcher)) -> BlueprintMocking.MainActorSyncStub<\(type), \(type)> {
                endpoint.matching(matcher)
            }
        }

        @Swift.MainActor
        public struct Verification {
            fileprivate let endpoint: \(endpoint)
            public func \(method)(\(matcherParameter): \(matcher), phase: BlueprintMocking.CallPhase = .admitted,
                                 origin: BlueprintMocking.CallOrigin? = nil) -> BlueprintMocking.MainActorVerification<\(type)> {
                endpoint.verification(matching: matcher, phase: phase, origin: origin)
            }
        }

        public var verify: Verification {
            guard let __blueprintEndpoint else { Swift.preconditionFailure("Mock setup is not ready") }
            return Verification(endpoint: __blueprintEndpoint)
        }

        public init(\(initParameter): \(type), failureReporter: BlueprintMocking.FailureReporter,
                    configure: @Swift.MainActor (Stubs) -> Swift.Void = { _ in }) {
            super.init(\(superInitializer))
            let setup = \(stubbing)()
            configure(Stubs(endpoint: setup))
            __blueprintEndpoint = \(endpoint)(
                id: BlueprintMocking.EndpointID(\(String(reflecting: identity))),
                configuration: setup.finish(), failureReporter: failureReporter,
                forwarding: { [unowned self] input in self.__blueprintCallSuper(input) }
            )
        }

        public override func \(method)(\(methodParameter): \(type)) -> \(type) {
            guard let __blueprintEndpoint else { return super.\(method)(\(superArgument)) }
            return __blueprintEndpoint.invoke(input, source: \(location))
        }

        private func __blueprintCallSuper(_ input: \(type)) -> \(type) {
            super.\(method)(\(superArgument))
        }
    }

    """
}

struct FinalFacadeGenerationRequest {
    let module: String
    let interfacePath: String
    let contextPath: String
    let name: String
    let selector: String
    let output: String

    init(arguments: ArraySlice<String>) throws {
        let values = Array(arguments)
        guard values.count == 11, values[0] == "--interface", values[3] == "--importer-context",
              values[5] == "--class", values[7] == "--method", values[9] == "--output",
              ProtocolSourceIndex.isConditionIdentifier(values[1]),
              ProtocolSourceIndex.isConditionIdentifier(values[6]),
              !["Swift", "BlueprintMocking"].contains(values[1]),
              !Parser.parse(source: "import \(values[1])").hasError else {
            throw GenerationError(description: "error: BPM002: usage: facade --interface MODULE FILE "
                                  + "--importer-context FILE --class NAME --method 'method(label:)' --output FILE")
        }
        module = values[1]
        interfacePath = values[2]
        contextPath = values[4]
        name = values[6]
        selector = values[8]
        output = values[10]
    }
}

private struct FinalFacadeInterface {
    let module: String
    let name: String
    let method: String
    let label: String
    let origin: ProtocolSourceOrigin
}

func generateFinalFacade(_ request: FinalFacadeGenerationRequest) throws -> String {
    let supplied = try ImportedInterfaceInput(module: request.module, path: request.interfacePath,
                                              contextPath: request.contextPath)
    let index = ProtocolSourceIndex(sources: [:], importedInterface: supplied)
    let type = try index.selectImportedClass(request.name, in: request.module, diagnosticFile: request.interfacePath)

    func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
        throw GenerationError(description: "\(index.origin(of: node)): error: BPM001: \(message)")
    }

    func scalar(_ type: TypeSyntax, named name: String) -> Bool {
        let spelling = type.trimmedDescription
        return spelling == "Swift.\(name)" || spelling == "Swift::\(name)"
    }

    let modifiers = type.modifiers.map(\.name.text)
    let inheritance = type.inheritanceClause?.inheritedTypes
    guard modifiers.count == 2, Set(modifiers) == ["public", "final"],
          type.attributes.isEmpty, type.genericParameterClause == nil, type.genericWhereClause == nil,
          inheritance?.count == 1, let trait = inheritance?.first, scalar(trait.type, named: "Sendable") else {
        try reject(type, "A final facade requires a public non-generic final class with a direct checked Swift.Sendable conformance")
    }
    let selected = type.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }.filter { method in
        let labels = method.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
        return "\(method.name.text)(\(labels))" == request.selector
    }
    guard selected.count == 1, let method = selected.first else {
        try reject(type, "The public SDK interface does not expose a unique method '\(request.selector)'. "
                   + "Select a public instance method or obtain an SDK-owner facade.")
    }
    let methodModifiers = method.modifiers.map(\.name.text).sorted()
    let parameters = method.signature.parameterClause.parameters
    guard methodModifiers == ["final", "public"] || methodModifiers == ["public"] else {
        try reject(method, "A final facade needs a public instance method in the SDK interface")
    }
    guard method.attributes.isEmpty, method.body == nil, method.genericParameterClause == nil,
          method.genericWhereClause == nil, method.signature.effectSpecifiers == nil,
          ProtocolSourceIndex.isConditionIdentifier(method.name.text),
          !["verify", "Stubs", "Verification"].contains(method.name.text),
          parameters.count == 1, let parameter = parameters.first,
          ProtocolSourceIndex.isConditionIdentifier(parameter.firstName.text),
          parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
          parameter.defaultValue == nil, parameter.ellipsis == nil, scalar(parameter.type, named: "Int"),
          let result = method.signature.returnClause?.type, scalar(result, named: "Int") else {
        try reject(method, "A final facade requires one synchronous nonthrowing method taking Swift.Int and returning Swift.Int")
    }

    for name in [request.module, "Swift", "BlueprintMocking", request.name + "Facade",
                 request.name + "FacadeLive", request.name + "FacadeMock"] {
        try index.requireUnshadowedQualifier(name, at: method)
    }
    return renderFinalFacade(FinalFacadeInterface(module: request.module, name: request.name,
                                                   method: method.name.text, label: parameter.firstName.text,
                                                   origin: index.origin(of: method)))
}

private func renderFinalFacade(_ interface: FinalFacadeInterface) -> String {
    let nominal = "\(interface.module).\(interface.name)"
    let facade = interface.name + "Facade"
    let witness = "\(interface.method)(\(interface.label) input: Swift.Int) -> Swift.Int"
    let call = interface.label == "_" ? "input" : "\(interface.label): input"
    let matcher = "\(interface.label) matcher: BlueprintMocking.Matcher<Swift.Int>"
    let origin = interface.origin
    let source = "BlueprintMocking.SourceLocation(fileID: \(String(reflecting: origin.module + "/" + origin.fileName)), "
        + "filePath: \(String(reflecting: origin.fileName)), line: \(origin.line), column: \(origin.column))"
    let identity = "schema\(GeneratedContract.irSchemaVersion)|\(nominal)|facade:\(interface.method)(\(interface.label):Swift.Int)->Swift.Int|Sendable"
    return """
    // Generated by Blueprint Mocking. Schema \(GeneratedContract.irSchemaVersion). Do not edit.
    // Source: \(origin.fileName), final class \(nominal).
    import BlueprintMocking
    import \(interface.module)

    public protocol \(facade): Swift.Sendable {
        func \(witness)
    }

    public struct \(facade)Live: \(facade) {
        private let __sdk: \(nominal)

        public init(sdk: \(nominal)) { __sdk = sdk }

        public func \(witness) {
            __sdk.\(interface.method)(\(call))
        }
    }

    public final class \(facade)Mock: \(facade) {
        private let __schema: \(GeneratedContract.runtimeMarker).Type = \(GeneratedContract.runtimeMarker).self
        private let __endpoint: BlueprintMocking.SyncEndpoint<Swift.Int, Swift.Int>

        public struct Stubs {
            fileprivate let setup: BlueprintMocking.SyncStubbing<Swift.Int, Swift.Int>

            public func \(interface.method)(\(matcher)) -> BlueprintMocking.SyncStub<Swift.Int, Swift.Int> {
                setup.matching(matcher)
            }
        }

        public struct Verification: Swift.Sendable {
            fileprivate let endpoint: BlueprintMocking.SyncEndpoint<Swift.Int, Swift.Int>

            public func \(interface.method)(\(matcher), phase: BlueprintMocking.CallPhase = .admitted)
                -> BlueprintMocking.Verification<Swift.Int> {
                endpoint.verification(matching: matcher, phase: phase)
            }
        }

        public var verify: Verification { Verification(endpoint: __endpoint) }

        public init(failureReporter: BlueprintMocking.FailureReporter,
                    session: BlueprintMocking.MockSession = BlueprintMocking.MockSession(),
                    _ configure: (Stubs) -> Void) {
            let setup = BlueprintMocking.SyncStubbing<Swift.Int, Swift.Int>()
            configure(Stubs(setup: setup))
            __endpoint = BlueprintMocking.SyncEndpoint(
                id: BlueprintMocking.EndpointID(\(String(reflecting: identity))),
                configuration: setup.finish(), failureReporter: failureReporter, scope: session.makeMock()
            )
        }

        public func \(witness) {
            __endpoint.invoke(input, source: \(source))
        }
    }
    """ + "\n"
}
