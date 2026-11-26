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
    private var filesByRoot: [SyntaxIdentifier: SourceFile] = [:]
    private var modules: [String: ModuleDeclarations] = [:]

    init(sources: [String: [String]]) {
        pathsByModule = sources
    }

    private func load(_ module: String) throws -> ModuleDeclarations {
        if let declarations = modules[module] { return declarations }

        var files: [SyntaxIdentifier: SourceFile] = [:]
        var declarations: ModuleDeclarations = [:]
        var seenPaths: Set<String> = []
        for path in pathsByModule[module, default: []].sorted() {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { continue }
            let tree = Parser.parse(source: try String(contentsOfFile: path, encoding: .utf8))
            guard !tree.hasError else {
                let origin = ProtocolSourceOrigin(module: module, path: path, line: 1, column: 1)
                throw Self.error(at: origin, "Malformed Swift source. Fix parser errors before generation")
            }
            var file = SourceFile(module: module, path: path, tree: tree,
                                  converter: SourceLocationConverter(fileName: path, tree: tree))
            Self.visitTopLevel(in: tree.statements) { declaration, conditional in
                let origin = file.origin(of: declaration)
                if let imported = declaration.as(ImportDeclSyntax.self) {
                    file.imports.record(imported, at: origin, conditional: conditional)
                } else if let name = Self.typeName(of: declaration) {
                    declarations[name, default: []].append(Candidate(
                        declaration: declaration, origin: origin, isConditional: conditional
                    ))
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
        let site = file.origin(of: node)
        try requireUnshadowed(name, in: file.module, at: site)

        if let selective = file.imports.selectiveByName[name] {
            let locations = selective.map(\.description).joined(separator: ", ")
            throw Self.error(at: site, "Module qualifier '\(name)' is shadowed by a selective import. "
                             + "Candidates: \(locations)")
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
        if !competitors.isEmpty {
            throw Self.error(at: site, "Module qualifier '\(name)' is shadowed by an imported declaration. "
                             + "Candidates: " + Self.candidateLocations(competitors))
        }
    }

    func resolveSendable(from root: IndexedProtocol) throws -> [IndexedProtocol] {
        var resolved: [IndexedProtocol] = []
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
            guard declaration.modifiers.map(\.name.text) == ["public"],
                  declaration.attributes.isEmpty, declaration.primaryAssociatedTypeClause == nil,
                  declaration.genericWhereClause == nil else {
                throw Self.error(at: current.origin, "Protocol \(module).\(current.name) must be public, non-generic "
                                 + "and attribute-free for Sendable inheritance")
            }

            activePath.append(identity)
            defer { activePath.removeLast() }
            resolved.append(current)

            let inheritedTypes = declaration.inheritanceClause?.inheritedTypes ?? []
            let edges = inheritedTypes.sorted { $0.type.trimmedDescription < $1.type.trimmedDescription }
            for edge in edges {
                let site = origin(of: edge.type)
                if let name = Self.simpleName(edge.type) {
                    if name == "Sendable" {
                        try requireUnshadowed("Sendable", in: module, at: site,
                                              remedy: ". Use Swift.Sendable for the standard marker.")
                        hasSendable = true
                    } else {
                        let parentName = ProtocolName(module: module, name: name)
                        try visit(parent(named: parentName, at: site), referencedAt: site)
                    }
                } else if let qualified = edge.type.as(MemberTypeSyntax.self),
                          let qualifier = Self.simpleName(qualified.baseType), qualified.genericArgumentClause == nil,
                          Self.isSimple(qualified.name.text) {
                    let name = qualified.name.text
                    if qualifier == "Swift", name == "Sendable" {
                        try requireUnshadowedQualifier(qualifier, at: qualified.baseType)
                        hasSendable = true
                    } else {
                        let parentName = ProtocolName(module: qualifier, name: name)
                        if qualifier != module, !file(containing: edge).imports.unconditional.contains(qualifier) {
                            throw Self.error(at: site, "Foreign inherited protocol '\(parentName)' requires "
                                             + "an unconditional plain import \(qualifier) in the declaring file")
                        }
                        try requireUnshadowedQualifier(qualifier, at: qualified.baseType)
                        try visit(parent(named: parentName, at: site), referencedAt: site)
                    }
                } else {
                    throw Self.error(at: site, "Unsupported inherited type '\(edge.type.trimmedDescription)'. "
                                     + "Use a simple protocol name, Module.Protocol, or Sendable")
                }
            }
        }

        try visit(root, referencedAt: root.origin)
        guard hasSendable else {
            throw Self.error(at: root.origin, "Use a public Sendable protocol or inherit the standard Sendable marker")
        }
        return resolved
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
        guard let declarations = modules[module] else { return }
        let candidates = Self.shadows(named: name, in: declarations)
        guard !candidates.isEmpty else { return }
        throw Self.error(at: origin, "Inherited reference '\(name)' is shadowed by a local declaration. Candidates: "
                         + Self.candidateLocations(candidates) + remedy)
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
        candidates.map { "\($0.origin)" + ($0.isConditional ? " (#if)" : "") }.joined(separator: ", ")
    }

    private static func error(at origin: ProtocolSourceOrigin, _ message: String) -> GenerationError {
        GenerationError(description: "\(origin): error: BPM001: \(message)")
    }
}
