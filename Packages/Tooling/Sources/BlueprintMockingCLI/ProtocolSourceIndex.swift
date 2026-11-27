import Foundation
import SwiftParser
import SwiftSyntax

struct ProtocolSourceOrigin: CustomStringConvertible {
    let module: String
    let path: String
    let line: Int
    let column: Int

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
    var description: String { "\(path):\(line):\(column)" }
}

struct IndexedProtocol {
    let declaration: ProtocolDeclSyntax
    let origin: ProtocolSourceOrigin

    var name: String { declaration.name.text }
}

struct IteratorElementWitness {
    let type: String
    let origin: ProtocolSourceOrigin
}

struct InheritedPrimaryTypeBinding {
    let name: String
    let type: String
    let origin: ProtocolSourceOrigin
}

struct ResolvedProtocolInheritance {
    let declarations: [IndexedProtocol]
    let parentsByDeclaration: [SyntaxIdentifier: [SyntaxIdentifier]]
    let primaryTypeBindings: [InheritedPrimaryTypeBinding]
}

private func parseIndexedSource(_ text: String, module: String, path: String) -> SourceFileSyntax {
    #if BLUEPRINT_TEST_PUBLICATION
    if ProcessInfo.processInfo.environment["BLUEPRINT_TEST_OBSERVE_SOURCE_PARSE"] == "1" {
        FileHandle.standardError.write(Data("DX012 fixture: parse \(module) \(path)\n".utf8))
    }
    #endif
    return Parser.parse(source: text)
}

final class InvocationSourceParseMemo {
    private struct SourceIdentity: Hashable {
        let module: String
        let path: String
    }

    private var entries: [SourceIdentity: (text: String, tree: SourceFileSyntax)] = [:]

    func parse(_ text: String, module: String, path: String) -> SourceFileSyntax {
        let identity = SourceIdentity(module: module, path: path)
        // Source text has already been opened and decoded at this pass's usual
        // read point. Swift String equality alone allows different UTF-8 bytes.
        if let entry = entries[identity], entry.text.utf8.elementsEqual(text.utf8) {
            return entry.tree
        }
        let tree = parseIndexedSource(text, module: module, path: path)
        entries[identity] = (text, tree)
        return tree
    }
}

final class ProtocolSourceIndex {
    private struct SourceFile {
        let module: String
        let path: String
        let tree: SourceFileSyntax
        let converter: SourceLocationConverter
        var imports = FileImports()

        func origin(of node: some SyntaxProtocol) -> ProtocolSourceOrigin {
            let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            return ProtocolSourceOrigin(module: module, path: path, line: location.line, column: location.column)
        }
    }

    private struct FileImports {
        var ordinary: Set<String> = []
        var unconditional: Set<String> = []
        var selectiveByName: [String: [ProtocolSourceOrigin]] = [:]

        mutating func record(_ declaration: ImportDeclSyntax, at origin: ProtocolSourceOrigin, conditional: Bool) {
            if declaration.importKindSpecifier != nil {
                if let name = declaration.path.last?.name.text {
                    let identifier = ProtocolSourceIndex.unquotedIdentifier(name)
                    selectiveByName[identifier, default: []].append(origin)
                }
            } else if declaration.attributes.isEmpty, declaration.modifiers.isEmpty, declaration.path.count == 1,
                      let module = declaration.path.first?.name.text {
                let identifier = ProtocolSourceIndex.unquotedIdentifier(module)
                ordinary.insert(identifier)
                if !conditional { unconditional.insert(identifier) }
            }
        }
    }

    private struct Candidate {
        let declaration: DeclSyntax
        let origin: ProtocolSourceOrigin
        let isConditional: Bool

        var canBeImported: Bool {
            let modifiers = declaration.children(viewMode: .sourceAccurate)
                .compactMap { $0.as(DeclModifierListSyntax.self) }
            return modifiers.joined().contains { ["public", "open", "package"].contains($0.name.text) }
        }
    }

    private struct ProtocolName: Hashable, CustomStringConvertible {
        let module: String
        let name: String

        var description: String { "\(module).\(name)" }
    }

    private typealias ModuleDeclarations = [String: [Candidate]]

    private let pathsByModule: [String: [String]]
    private let importedInterface: ImportedInterfaceInput?
    private let conditions: [String: [String: Bool]]
    private let sourceParseMemo: InvocationSourceParseMemo?
    private let sourceFactsCache: SourceFactsCache?
    private var filesByRoot: [SyntaxIdentifier: SourceFile] = [:]
    private var modules: [String: ModuleDeclarations] = [:]

    init(sources: [String: [String]], conditions: [String: [String: Bool]] = [:],
         importedInterface: ImportedInterfaceInput? = nil, sourceParseMemo: InvocationSourceParseMemo? = nil,
         sourceFactsCache: SourceFactsCache? = nil) {
        self.importedInterface = importedInterface
        pathsByModule = importedInterface.map { [$0.module: [$0.path]] } ?? sources
        self.conditions = conditions
        self.sourceParseMemo = sourceParseMemo
        self.sourceFactsCache = sourceFactsCache
    }

    /// Selects the original syntax nodes in the active clauses of a protocol's member block.
    func activeMembers(of declaration: IndexedProtocol) throws -> [MemberBlockItemSyntax] {
        let module = declaration.origin.module
        var active: [MemberBlockItemSyntax] = []

        func collect(_ members: MemberBlockItemListSyntax) throws {
            for member in members {
                guard let directive = member.decl.as(IfConfigDeclSyntax.self) else {
                    active.append(member)
                    continue
                }
                let clauses = Array(directive.clauses)
                guard let first = clauses.first, first.poundKeyword.text == "#if" else {
                    throw Self.error(at: origin(of: directive), "Unsupported conditional compilation directive. "
                                     + "Use #if with an optional #else.")
                }
                if let unexpected = clauses.dropFirst().first(where: { $0.poundKeyword.text != "#else" }) {
                    throw Self.error(at: origin(of: unexpected.poundKeyword),
                                     "Unsupported conditional compilation directive. Use #if with an optional #else.")
                }
                guard clauses.count <= 2, clauses.dropFirst().first?.condition == nil else {
                    throw Self.error(at: origin(of: directive), "Unsupported conditional compilation directive. "
                                     + "Use #if with an optional #else.")
                }
                let negation = first.condition?.as(PrefixOperatorExprSyntax.self)
                guard let expression = first.condition, negation == nil || negation?.operator.text == "!",
                      let reference = (negation?.expression ?? expression).as(DeclReferenceExprSyntax.self),
                      reference.argumentNames == nil,
                      case .identifier(let flag) = reference.baseName.tokenKind,
                      Self.isConditionIdentifier(flag) else {
                    let site = first.condition.map { origin(of: $0) } ?? origin(of: first.poundKeyword)
                    throw Self.error(at: site, "Unsupported compilation condition. "
                                     + "Use one bare custom identifier in #if, optionally prefixed with !.")
                }
                guard let enabled = conditions[module]?[flag] else {
                    throw Self.error(at: origin(of: reference), "Missing compilation condition '\(flag)' for source module "
                                     + "'\(module)'. Supply --source-condition \(module) \(flag) true or false.")
                }
                let selectsFirst = negation == nil ? enabled : !enabled
                let selected = selectsFirst ? first : clauses.dropFirst().first
                guard let branch = selected, let payload = branch.elements else { continue }
                guard case .decls(let nested) = payload else {
                    throw Self.error(at: origin(of: branch), "Expected a protocol member block in the selected clause.")
                }
                try collect(nested)
            }
        }

        try collect(declaration.declaration.memberBlock.members)
        return active
    }

    static func isConditionIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private func load(_ module: String) throws -> ModuleDeclarations {
        if let declarations = modules[module] { return declarations }

        var files: [SyntaxIdentifier: SourceFile] = [:]
        var declarations: ModuleDeclarations = [:]
        var seenPaths: Set<String> = []
        for path in pathsByModule[module, default: []].sorted() {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { continue }
            let swiftText: String
            var cacheable: SourceFactsCache.Source?
            if let supplied = importedInterface, supplied.path == path, supplied.module == module {
                swiftText = supplied.text
            } else {
                guard URL(fileURLWithPath: path).pathExtension != "swiftinterface" else {
                    throw IncompatibleImporterContext(path: path, reason: "Textual module input requires --interface and --importer-context")
                }
                cacheable = sourceFactsCache?.readSource(at: path)
                if let cacheable, sourceFactsCache?.skipsIndexing(cacheable) == true { continue }
                swiftText = try cacheable?.text ?? String(contentsOfFile: path, encoding: .utf8)
            }
            // Only erase no-op components for source locations. Parent traversal can cross a symbolic link.
            let displayPath = path.split(separator: "/", omittingEmptySubsequences: false)
                .filter { $0 != "." }.joined(separator: "/")
            let tree = sourceParseMemo?.parse(swiftText, module: module, path: path)
                ?? parseIndexedSource(swiftText, module: module, path: path)
            guard !tree.hasError else {
                if importedInterface != nil {
                    throw IncompatibleImporterContext(path: path, reason: "The installed SwiftSyntax parser cannot read this interface syntax")
                }
                let origin = ProtocolSourceOrigin(module: module, path: displayPath, line: 1, column: 1)
                throw Self.error(at: origin, "Malformed Swift source. Fix parser errors before generation")
            }
            if let cacheable, tree.statements.allSatisfy({ $0.item.is(FunctionDeclSyntax.self) }) {
                sourceFactsCache?.rememberNoIndexableDeclarations(cacheable)
            }
            var file = SourceFile(module: module, path: displayPath, tree: tree,
                                  converter: SourceLocationConverter(fileName: displayPath, tree: tree))
            var hasComplexInterfaceImport = false
            Self.visitTopLevel(in: tree.statements) { declaration, conditional in
                let origin = file.origin(of: declaration)
                if let imported = declaration.as(ImportDeclSyntax.self) {
                    if importedInterface != nil,
                       conditional || !imported.attributes.isEmpty || !imported.modifiers.isEmpty ||
                       imported.importKindSpecifier != nil || imported.path.count != 1 {
                        hasComplexInterfaceImport = true
                    }
                    file.imports.record(imported, at: origin, conditional: conditional)
                } else if let name = Self.typeName(of: declaration) {
                    declarations[name, default: []].append(Candidate(
                        declaration: declaration, origin: origin, isConditional: conditional
                    ))
                }
            }
            if importedInterface != nil {
                let swiftModules: Set<String> = ["Swift", "_Concurrency", "_StringProcessing", "_SwiftConcurrencyShims"]
                guard !hasComplexInterfaceImport, file.imports.ordinary.isSubset(of: swiftModules) else {
                    throw IncompatibleImporterContext(path: path, reason: "The interface imports dependencies outside the core Swift profile")
                }
            }
            files[file.tree.id] = file
        }
        for (root, file) in files {
            filesByRoot[root] = file
        }
        modules[module] = declarations
        return declarations
    }

    func select(_ name: String, in module: String, diagnosticFile: String) throws -> IndexedProtocol {
        let candidates = try load(module)[name, default: []]
        guard candidates.count == 1, let candidate = candidates.first, !candidate.isConditional,
              let declaration = candidate.declaration.as(ProtocolDeclSyntax.self) else {
            let origin = ProtocolSourceOrigin(module: module, path: diagnosticFile, line: 1, column: 1)
            let details = candidates.isEmpty ? "" : ". Candidates: " + Self.candidateLocations(candidates)
            throw Self.error(at: origin, "Expected one top-level protocol \(module).\(name) in the supplied source inputs"
                             + details)
        }
        return IndexedProtocol(declaration: declaration, origin: candidate.origin)
    }

    func selectImportedClass(_ name: String, in module: String, diagnosticFile: String) throws -> ClassDeclSyntax {
        let candidates = try load(module)[name, default: []]
        guard importedInterface?.module == module, candidates.count == 1,
              let candidate = candidates.first, !candidate.isConditional,
              let declaration = candidate.declaration.as(ClassDeclSyntax.self) else {
            let site = ProtocolSourceOrigin(module: module, path: diagnosticFile, line: 1, column: 1)
            throw Self.error(at: site, "Expected one top-level class \(module).\(name) in the public SDK interface")
        }
        return declaration
    }

    /// Diagnoses when a supplied, unconditional final superclass fixes Self to one class.
    func requireReplaceableSelf(of protocolType: IndexedProtocol) throws {
        guard let clause = protocolType.declaration.genericWhereClause else { return }
        let module = protocolType.origin.module
        let declarations = try load(module)
        for requirement in clause.requirements {
            guard case .conformanceRequirement(let bound) = requirement.requirement,
                  bound.leftType.trimmedDescription == "Self",
                  let name = Self.simpleName(bound.rightType) else { continue }
            let candidates = Self.shadows(named: name, in: declarations)
            guard candidates.count == 1, let candidate = candidates.first, !candidate.isConditional,
                  let concrete = candidate.declaration.as(ClassDeclSyntax.self),
                  concrete.modifiers.contains(where: { $0.name.text == "final" }),
                  concrete.genericParameterClause == nil else { continue }
            throw Self.error(at: origin(of: bound), "Self is fixed to final class '\(module).\(name)'. "
                             + "Use a protocol or closure adapter at the consuming boundary.")
        }
    }

    func origin(of node: some SyntaxProtocol) -> ProtocolSourceOrigin {
        file(containing: node).origin(of: node)
    }

    private func file(containing node: some SyntaxProtocol) -> SourceFile {
        guard let file = filesByRoot[node.root.id] else {
            preconditionFailure("Expected a syntax node from the indexed source files")
        }
        return file
    }

    /// Checks known local type declarations in a module already visited by the source index.
    func isUnshadowed(_ name: String, in module: String) -> Bool {
        guard let declarations = modules[module] else { return false }
        return Self.shadows(named: name, in: declarations).isEmpty
    }

    /// Rejects qualifier shadows that can be found in the supplied source and the declaring file's imports.
    func requireUnshadowedQualifier(_ name: String, at node: some SyntaxProtocol) throws {
        let file = file(containing: node)
        if let conflict = try qualifierShadow(name, in: file) {
            throw Self.error(at: file.origin(of: node), conflict)
        }
    }

    private func qualifierShadow(_ name: String, in file: SourceFile) throws -> String? {
        if let local = localShadow(name, in: file.module) { return local }
        if let selective = file.imports.selectiveByName[name] {
            let locations = selective.map(\.description).joined(separator: ", ")
            return "Module qualifier '\(name)' is shadowed by a selective import. Candidates: \(locations)"
        }

        let suppliedImports = file.imports.ordinary.sorted().filter { module in
            module != file.module && pathsByModule[module]?.isEmpty == false
        }
        var competitors: [Candidate] = []
        for module in suppliedImports {
            let imported = try load(module)
            let exported = Self.shadows(named: name, in: imported).filter(\.canBeImported)
            competitors.append(contentsOf: exported)
        }
        guard !competitors.isEmpty else { return nil }
        return "Module qualifier '\(name)' is shadowed by an imported declaration. Candidates: "
            + Self.candidateLocations(competitors)
    }

    func requireConstructionFailureEnum(named name: String, at reference: some SyntaxProtocol) throws {
        let site = origin(of: reference)
        let candidates = try Self.shadows(named: name, in: load(site.module))
        guard Self.isSimple(name), candidates.count == 1, let candidate = candidates.first,
              !candidate.isConditional, let failure = candidate.declaration.as(EnumDeclSyntax.self),
              failure.name.text == name, failure.attributes.isEmpty, failure.modifiers.map(\.name.text) == ["public"],
              failure.genericParameterClause == nil, failure.genericWhereClause == nil,
              let conformances = failure.inheritanceClause?.inheritedTypes,
              conformances.contains(where: { ["Error", "Swift.Error"].contains($0.type.trimmedDescription) }),
              conformances.allSatisfy({
                  ["Error", "Swift.Error", "Equatable", "Swift.Equatable"].contains($0.type.trimmedDescription)
              }) else {
            throw Self.error(at: site, "Typed construction requires a public same-module non-generic enum "
                             + "with direct Swift.Error conformance.")
        }
        for conformance in conformances {
            let spelling = conformance.type.trimmedDescription
            try requireUnshadowedQualifier(spelling.hasPrefix("Swift.") ? "Swift" : spelling, at: conformance.type)
        }
    }

    func requireTransferClass(named name: String, at reference: some SyntaxProtocol) throws {
        let site = origin(of: reference)
        let candidates = try Self.shadows(named: name, in: load(site.module))
        guard Self.isSimple(name), candidates.count == 1, let candidate = candidates.first,
              !candidate.isConditional, let concrete = candidate.declaration.as(ClassDeclSyntax.self),
              concrete.name.text == name, concrete.attributes.isEmpty,
              Set(concrete.modifiers.map(\.name.text)) == ["public", "final"],
              concrete.genericParameterClause == nil, concrete.genericWhereClause == nil,
              concrete.inheritanceClause == nil else {
            throw Self.error(at: site, "A sending transfer requires one unconditional public final nongeneric class "
                             + "'\(site.module).\(name)' without an inheritance clause")
        }
    }

    func requireConcreteActor(named name: String, at reference: some SyntaxProtocol) throws {
        let site = origin(of: reference)
        let candidates = try Self.shadows(named: name, in: load(site.module))
        guard Self.isSimple(name), candidates.count == 1, let candidate = candidates.first,
              !candidate.isConditional, let actor = candidate.declaration.as(ActorDeclSyntax.self),
              actor.name.text == name, actor.attributes.isEmpty, actor.modifiers.map(\.name.text) == ["public"],
              actor.genericParameterClause == nil, actor.genericWhereClause == nil else {
            throw Self.error(at: site, "An isolated parameter requires one unconditional public nongeneric actor "
                             + "'\(site.module).\(name)' declared in the supplied module.")
        }
    }

    private static func explicitNoncopyableMarker(in declaration: DeclSyntax) -> TypeSyntax? {
        declaration.as(StructDeclSyntax.self)?.inheritanceClause?.inheritedTypes.lazy.compactMap {
            $0.type.as(SuppressedTypeSyntax.self)?.type
        }.first { ["Copyable", "Swift.Copyable"].contains($0.trimmedDescription) }
    }

    func hasExplicitNoncopyableStruct(named name: String, at reference: some SyntaxProtocol) throws -> Bool {
        let candidates = try Self.shadows(named: name, in: load(origin(of: reference).module))
        return candidates.contains { Self.explicitNoncopyableMarker(in: $0.declaration) != nil }
    }

    func requireNoncopyableStruct(
        named name: String, at reference: some SyntaxProtocol, subject: String = "A consuming input"
    ) throws {
        let site = origin(of: reference)
        let candidates = try Self.shadows(named: name, in: load(site.module))
        guard Self.isSimple(name), candidates.count == 1, let candidate = candidates.first,
              !candidate.isConditional, let value = candidate.declaration.as(StructDeclSyntax.self),
              value.name.text == name, value.attributes.isEmpty, value.modifiers.map(\.name.text) == ["public"],
              value.genericParameterClause == nil, value.genericWhereClause == nil,
              let marker = Self.explicitNoncopyableMarker(in: candidate.declaration) else {
            throw Self.error(at: site, "\(subject) requires one unconditional public nongeneric struct "
                             + "'\(site.module).\(name)' with an explicit ~Copyable declaration.")
        }
        try requireUnshadowedQualifier(marker.trimmedDescription == "Copyable" ? "Copyable" : "Swift", at: marker)
    }

    /// Resolves a lexical nominal used by the restricted availability profile.
    func requireAvailabilityStruct(named name: String, at reference: some SyntaxProtocol) throws -> StructDeclSyntax {
        let site = origin(of: reference)
        let declarations = try load(site.module)
        let candidates = Self.shadows(named: name, in: declarations)
        guard Self.isSimple(name), candidates.count == 1, let candidate = candidates.first,
              !candidate.isConditional, let concrete = candidate.declaration.as(StructDeclSyntax.self),
              concrete.name.text == name, concrete.modifiers.map(\.name.text) == ["public"],
              concrete.genericParameterClause == nil, concrete.genericWhereClause == nil else {
            let details = candidates.isEmpty ? "" : " Candidates: " + Self.candidateLocations(candidates) + "."
            throw Self.error(at: site, "Cannot verify macOS availability of '\(site.module).\(name)' from supplied source. "
                             + "Use an unconditional public, nongeneric struct declared in this module." + details)
        }
        return concrete
    }

    func iteratorElementWitness(
        named name: String, in module: String, at constraint: some SyntaxProtocol
    ) throws -> IteratorElementWitness {
        let site = origin(of: constraint)
        let qualified = "\(module).\(name)"
        func unresolved(_ remedy: String) throws -> Never {
            throw Self.error(at: site, "Cannot resolve '\(qualified).Element' from supplied source. \(remedy)")
        }

        let declarations = try load(module)
        let candidates = Self.shadows(named: name, in: declarations)
        guard candidates.count == 1, let candidate = candidates.first, !candidate.isConditional,
              let concrete = candidate.declaration.as(StructDeclSyntax.self), concrete.name.text == name,
              concrete.attributes.isEmpty, concrete.modifiers.map(\.name.text) == ["public"],
              concrete.genericParameterClause == nil, concrete.genericWhereClause == nil else {
            let found = candidates.isEmpty ? "" : " Candidates: " + Self.candidateLocations(candidates)
            try unresolved("Supply one unconditional public, nongeneric struct '\(qualified)'." + found)
        }

        let conformances = concrete.inheritanceClause?.inheritedTypes.compactMap {
            Self.explicitSwiftMember($0.type)
        } ?? []
        guard conformances.contains("IteratorProtocol"), conformances.contains("Sendable") else {
            try unresolved("Declare Swift.IteratorProtocol and Swift.Sendable directly on the struct at \(candidate.origin).")
        }

        let members = Self.iteratorWitnessMembers(in: concrete.memberBlock.members)
        if let shadow = members.first(where: { $0.name == "Swift" }) {
            try unresolved("Use an unshadowed Swift qualifier. Nested declaration at \(origin(of: shadow.declaration)).")
        }
        let elements = members.filter { $0.name == "Element" }
        guard elements.count == 1, let member = elements.first, !member.isConditional,
              let alias = member.declaration.as(TypeAliasDeclSyntax.self), alias.name.text == "Element",
              alias.attributes.isEmpty, alias.modifiers.map(\.name.text) == ["public"],
              alias.genericParameterClause == nil, alias.genericWhereClause == nil,
              let scalar = Self.explicitSwiftMember(alias.initializer.value),
              ["Bool", "Int", "String"].contains(scalar) else {
            let locations = elements.map { origin(of: $0.declaration).description }.joined(separator: ", ")
            let found = locations.isEmpty ? "" : " Candidates: \(locations)."
            try unresolved("Declare exactly one unconditional public typealias Element = "
                           + "Swift.Bool, Swift.Int or Swift.String directly in the struct." + found)
        }
        if let conflict = iteratorExtensionConflict(named: name, in: module) {
            try unresolved("A supplied extension could change Element or Swift lookup. Conflicting declaration at \(conflict).")
        }

        let witnessFile = file(containing: concrete)
        if let shadow = try qualifierShadow("Swift", in: witnessFile) {
            try unresolved("Use an unshadowed Swift qualifier. " + shadow)
        }
        if let shadow = localShadow(module, in: module) {
            try unresolved("Use an unshadowed '\(module)' module qualifier. " + shadow)
        }
        if let shadow = try qualifierShadow(module, in: file(containing: constraint)) {
            try unresolved("Use an unshadowed '\(module)' module qualifier. " + shadow)
        }

        return IteratorElementWitness(type: "Swift.\(scalar)", origin: origin(of: alias))
    }

    func resolveSendable(from root: IndexedProtocol) throws -> ResolvedProtocolInheritance {
        var resolved: [IndexedProtocol] = []
        var parentsByDeclaration: [SyntaxIdentifier: [SyntaxIdentifier]] = [:]
        var primaryTypeBindings: [InheritedPrimaryTypeBinding] = []
        var activePath: [ProtocolName] = []
        var visited: Set<ProtocolName> = []
        var hasSendable = false

        func visit(_ current: IndexedProtocol, referencedAt reference: ProtocolSourceOrigin) throws {
            let module = current.origin.module
            let identity = ProtocolName(module: module, name: current.name)
            if let first = activePath.firstIndex(of: identity) {
                let chain = activePath[first...] + [identity]
                let crossesModules = chain.contains { $0.module != module }
                let cycle = chain.map { crossesModules ? $0.description : $0.name }.joined(separator: " -> ")
                throw Self.error(at: reference, "Protocol inheritance cycle: \(cycle)")
            }
            guard visited.insert(identity).inserted else { return }

            let declaration = current.declaration
            if declaration.id != root.declaration.id {
                try requireReplaceableSelf(of: current)
            }
            guard declaration.modifiers.map(\.name.text) == ["public"],
                  declaration.attributes.isEmpty, declaration.genericWhereClause == nil else {
                throw Self.error(at: current.origin, "Protocol \(module).\(current.name) must be public, non-generic "
                                 + "and attribute-free for Sendable inheritance")
            }

            activePath.append(identity)
            defer { activePath.removeLast() }
            resolved.append(current)
            parentsByDeclaration[declaration.id] = []

            let inheritedTypes = declaration.inheritanceClause?.inheritedTypes ?? []
            let edges = inheritedTypes.sorted { $0.type.trimmedDescription < $1.type.trimmedDescription }
            for edge in edges {
                let site = origin(of: edge.type)
                let parentName: ProtocolName
                let arguments: GenericArgumentClauseSyntax?
                if let identifier = edge.type.as(IdentifierTypeSyntax.self), Self.isSimple(identifier.name.text) {
                    let name = identifier.name.text
                    arguments = identifier.genericArgumentClause
                    if name == "Sendable" {
                        guard arguments == nil else {
                            throw Self.error(at: site, "The Sendable marker cannot take inherited type arguments")
                        }
                        try requireUnshadowed("Sendable", in: module, at: site,
                                              remedy: ". Use Swift.Sendable for the standard marker.")
                        hasSendable = true
                        continue
                    }
                    parentName = ProtocolName(module: module, name: name)
                } else if let qualified = edge.type.as(MemberTypeSyntax.self),
                          let qualifier = Self.simpleName(qualified.baseType), Self.isSimple(qualified.name.text) {
                    let name = qualified.name.text
                    arguments = qualified.genericArgumentClause
                    if qualifier == "Swift", name == "Sendable" {
                        guard arguments == nil else {
                            throw Self.error(at: site, "The Sendable marker cannot take inherited type arguments")
                        }
                        try requireUnshadowedQualifier(qualifier, at: qualified.baseType)
                        hasSendable = true
                        continue
                    }
                    parentName = ProtocolName(module: qualifier, name: name)
                    if qualifier != module, !file(containing: edge).imports.unconditional.contains(qualifier) {
                        throw Self.error(at: site, "Foreign inherited protocol '\(parentName)' requires "
                                         + "an unconditional plain import \(qualifier) in the declaring file")
                    }
                    try requireUnshadowedQualifier(qualifier, at: qualified.baseType)
                } else {
                    throw Self.error(at: site, "Unsupported inherited type '\(edge.type.trimmedDescription)'. "
                                     + "Use a simple protocol name, Module.Protocol, or Sendable")
                }

                let inherited = try parent(named: parentName, at: site)
                if let arguments {
                    primaryTypeBindings.append(try primaryTypeBinding(for: inherited, arguments: arguments))
                }
                parentsByDeclaration[declaration.id, default: []].append(inherited.declaration.id)
                try visit(inherited, referencedAt: site)
            }
        }

        try visit(root, referencedAt: root.origin)
        guard hasSendable else {
            throw Self.error(at: root.origin, "Use a public Sendable protocol or inherit the standard Sendable marker")
        }
        return ResolvedProtocolInheritance(declarations: resolved, parentsByDeclaration: parentsByDeclaration,
                                           primaryTypeBindings: primaryTypeBindings)
    }

    private func primaryTypeBinding(
        for parent: IndexedProtocol, arguments clause: GenericArgumentClauseSyntax
    ) throws -> InheritedPrimaryTypeBinding {
        let primary = parent.declaration.primaryAssociatedTypeClause?.primaryAssociatedTypes ?? []
        guard primary.count == 1, let parameter = primary.first,
              clause.arguments.count == 1, let argument = clause.arguments.first else {
            throw Self.error(at: origin(of: clause), "Specialized inherited protocol "
                             + "'\(parent.origin.module).\(parent.name)' requires exactly one primary associated type "
                             + "and one concrete argument")
        }

        // SwiftSyntax 600 exposes a type directly. Later parsers can also represent a value argument.
        let type = Syntax(argument.argument)
        let argumentOrigin = origin(of: type)
        let name = parameter.name.text
        guard let scalar = type.as(MemberTypeSyntax.self), scalar.genericArgumentClause == nil,
              Self.simpleName(scalar.baseType) == "Swift",
              ["Bool", "Int", "String"].contains(scalar.name.text) else {
            throw Self.error(at: argumentOrigin, "Unsupported inherited specialization argument for '\(name)'. "
                             + "Use Swift.Bool, Swift.Int or Swift.String")
        }
        try requireUnshadowedQualifier("Swift", at: scalar.baseType)
        return InheritedPrimaryTypeBinding(name: name, type: "Swift.\(scalar.name.text)", origin: argumentOrigin)
    }

    private func parent(named name: ProtocolName, at origin: ProtocolSourceOrigin) throws -> IndexedProtocol {
        let candidates = try load(name.module)[name.name, default: []]
        guard !candidates.isEmpty else {
            throw Self.error(at: origin, "Missing inherited protocol \(name) in the supplied source inputs")
        }
        guard candidates.count == 1, let candidate = candidates.first, !candidate.isConditional else {
            throw Self.error(at: origin, "Ambiguous inherited protocol \(name). Candidates: "
                             + Self.candidateLocations(candidates))
        }
        guard let declaration = candidate.declaration.as(ProtocolDeclSyntax.self) else {
            throw Self.error(at: origin, "Inherited type \(name) is not a top-level protocol. "
                             + "Declaration: \(candidate.origin)")
        }
        return IndexedProtocol(declaration: declaration, origin: candidate.origin)
    }

    private func requireUnshadowed(
        _ name: String, in module: String, at origin: ProtocolSourceOrigin, remedy: String = ""
    ) throws {
        if let shadow = localShadow(name, in: module) {
            throw Self.error(at: origin, shadow + remedy)
        }
    }

    private func localShadow(_ name: String, in module: String) -> String? {
        guard let declarations = modules[module] else { return nil }
        let candidates = Self.shadows(named: name, in: declarations)
        guard !candidates.isEmpty else { return nil }
        return "Inherited reference '\(name)' is shadowed by a local declaration. Candidates: "
            + Self.candidateLocations(candidates)
    }

    private static func shadows(named name: String, in declarations: ModuleDeclarations) -> [Candidate] {
        declarations[name, default: []] + declarations["`\(name)`", default: []]
    }

    private static func unquotedIdentifier(_ spelling: String) -> String {
        guard spelling.first == "`", spelling.last == "`" else { return spelling }
        return String(spelling.dropFirst().dropLast())
    }

    private static func visitTopLevel(
        in statements: CodeBlockItemListSyntax, conditional: Bool = false,
        _ record: (DeclSyntax, Bool) -> Void
    ) {
        for statement in statements {
            if let configuration = statement.item.as(IfConfigDeclSyntax.self) {
                for clause in configuration.clauses {
                    if case .statements(let branch)? = clause.elements {
                        visitTopLevel(in: branch, conditional: true, record)
                    }
                }
            } else if let declaration = statement.item.as(DeclSyntax.self) {
                record(declaration, conditional)
            }
        }
    }

    private typealias IteratorWitnessMember = (name: String, declaration: DeclSyntax, isConditional: Bool)

    private static func iteratorWitnessMembers(
        in members: MemberBlockItemListSyntax, conditional: Bool = false
    ) -> [IteratorWitnessMember] {
        var matches: [IteratorWitnessMember] = []
        for member in members {
            if let configuration = member.decl.as(IfConfigDeclSyntax.self) {
                for clause in configuration.clauses {
                    if case .decls(let branch)? = clause.elements {
                        matches.append(contentsOf: iteratorWitnessMembers(in: branch, conditional: true))
                    }
                }
            } else if let spelling = typeName(of: member.decl) {
                let name = unquotedIdentifier(spelling)
                if name == "Element" || name == "Swift" {
                    matches.append((name, member.decl, conditional))
                }
            }
        }
        return matches
    }

    private func iteratorExtensionConflict(named name: String, in module: String) -> ProtocolSourceOrigin? {
        let files = filesByRoot.values.filter { $0.module == module }.sorted { $0.path < $1.path }
        for file in files {
            var conflict: ProtocolSourceOrigin?
            Self.visitTopLevel(in: file.tree.statements) { declaration, _ in
                guard conflict == nil, let extensionDecl = declaration.as(ExtensionDeclSyntax.self),
                      let member = Self.iteratorWitnessMembers(in: extensionDecl.memberBlock.members).first else {
                    return
                }
                // An extension with an unresolved target could reach the iterator through a typealias.
                let target = Self.localExtensionTarget(extensionDecl.extendedType, in: module)
                if let target, target != name, let declarations = modules[module] {
                    let candidates = Self.shadows(named: target, in: declarations)
                    if candidates.count == 1, let candidate = candidates.first,
                       !candidate.isConditional, !candidate.declaration.is(TypeAliasDeclSyntax.self) {
                        return
                    }
                }
                conflict = file.origin(of: member.declaration)
            }
            if let conflict { return conflict }
        }
        return nil
    }

    private static func localExtensionTarget(_ type: TypeSyntax, in module: String) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return unquotedIdentifier(identifier.name.text)
        }
        guard let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
              let qualifier = member.baseType.as(IdentifierTypeSyntax.self), qualifier.genericArgumentClause == nil,
              unquotedIdentifier(qualifier.name.text) == module else { return nil }
        return unquotedIdentifier(member.name.text)
    }

    private static func explicitSwiftMember(_ type: TypeSyntax) -> String? {
        guard let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
              simpleName(member.baseType) == "Swift" else { return nil }
        return member.name.text
    }

    private static func typeName(of declaration: DeclSyntax) -> String? {
        switch declaration.kind {
        case .protocolDecl: declaration.as(ProtocolDeclSyntax.self)?.name.text
        case .typeAliasDecl: declaration.as(TypeAliasDeclSyntax.self)?.name.text
        case .structDecl: declaration.as(StructDeclSyntax.self)?.name.text
        case .enumDecl: declaration.as(EnumDeclSyntax.self)?.name.text
        case .classDecl: declaration.as(ClassDeclSyntax.self)?.name.text
        case .actorDecl: declaration.as(ActorDeclSyntax.self)?.name.text
        default: nil
        }
    }

    private static func simpleName(_ type: TypeSyntax) -> String? {
        guard let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil,
              isSimple(identifier.name.text) else { return nil }
        return identifier.name.text
    }

    private static func isSimple(_ name: String) -> Bool {
        name.first?.isLetter == true
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func candidateLocations(_ candidates: [Candidate]) -> String {
        let ordered = candidates.sorted {
            ($0.origin.path, $0.origin.line, $0.origin.column) < ($1.origin.path, $1.origin.line, $1.origin.column)
        }
        return ordered.map { "\($0.origin)" + ($0.isConditional ? " (#if)" : "") }.joined(separator: ", ")
    }

    private static func error(at origin: ProtocolSourceOrigin, _ message: String) -> GenerationError {
        GenerationError(description: "\(origin): error: BPM001: \(message)")
    }
}
