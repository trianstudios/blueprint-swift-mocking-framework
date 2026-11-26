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

struct ProtocolSourceIndex {
    private struct SourceFile {
        let path: String
        let tree: SourceFileSyntax
        let converter: SourceLocationConverter

        func origin(of node: some SyntaxProtocol, module: String) -> ProtocolSourceOrigin {
            let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            return ProtocolSourceOrigin(module: module, path: path, line: location.line, column: location.column)
        }
    }

    private struct Candidate {
        let declaration: DeclSyntax
        let origin: ProtocolSourceOrigin
        let isConditional: Bool
    }

    private let module: String
    private let filesByRoot: [SyntaxIdentifier: SourceFile]
    private let declarationsByName: [String: [Candidate]]

    init(module: String, paths: [String]) throws {
        var files: [SyntaxIdentifier: SourceFile] = [:]
        var declarations: [String: [Candidate]] = [:]
        var seenPaths: Set<String> = []
        for path in paths.sorted() {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { continue }
            let tree = Parser.parse(source: try String(contentsOfFile: path, encoding: .utf8))
            guard !tree.hasError else {
                let origin = ProtocolSourceOrigin(module: module, path: path, line: 1, column: 1)
                throw Self.error(at: origin, "Malformed Swift source. Fix parser errors before generation")
            }
            let file = SourceFile(path: path, tree: tree,
                                  converter: SourceLocationConverter(fileName: path, tree: tree))
            files[file.tree.id] = file
            Self.visitTopLevel(in: tree.statements) { name, declaration, conditional in
                declarations[name, default: []].append(Candidate(
                    declaration: declaration, origin: file.origin(of: declaration, module: module),
                    isConditional: conditional
                ))
            }
        }
        self.module = module
        self.filesByRoot = files
        self.declarationsByName = declarations
    }

    func select(_ name: String, diagnosticFile: String) throws -> IndexedProtocol {
        let candidates = declarationsByName[name, default: []]
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
        guard let file = filesByRoot[node.root.id] else {
            preconditionFailure("Expected a syntax node from the indexed source files")
        }
        return file.origin(of: node, module: module)
    }

    func resolveSendable(from root: IndexedProtocol) throws -> [IndexedProtocol] {
        var resolved: [IndexedProtocol] = []
        var activePath: [String] = []
        var visited: Set<String> = []
        var hasSendable = false

        func visit(_ current: IndexedProtocol, referencedAt reference: ProtocolSourceOrigin) throws {
            if let first = activePath.firstIndex(of: current.name) {
                let cycle = (activePath[first...] + [current.name]).joined(separator: " -> ")
                throw Self.error(at: reference, "Protocol inheritance cycle: \(cycle)")
            }
            guard visited.insert(current.name).inserted else { return }

            let declaration = current.declaration
            guard declaration.modifiers.map(\.name.text) == ["public"],
                  declaration.attributes.isEmpty, declaration.primaryAssociatedTypeClause == nil,
                  declaration.genericWhereClause == nil else {
                throw Self.error(at: current.origin, "Protocol \(module).\(current.name) must be public, non-generic "
                                 + "and attribute-free for Sendable inheritance")
            }

            activePath.append(current.name)
            defer { activePath.removeLast() }
            resolved.append(current)

            let inheritedTypes = declaration.inheritanceClause?.inheritedTypes ?? []
            let edges = inheritedTypes.sorted { $0.type.trimmedDescription < $1.type.trimmedDescription }
            for edge in edges {
                let site = origin(of: edge.type)
                if let name = Self.simpleName(edge.type) {
                    if name == "Sendable" {
                        try requireUnshadowed("Sendable", at: site, remedy: ". Use Swift.Sendable for the standard marker.")
                        hasSendable = true
                    } else {
                        try visit(parent(named: name, at: site), referencedAt: site)
                    }
                } else if let qualified = edge.type.as(MemberTypeSyntax.self),
                          let qualifier = Self.simpleName(qualified.baseType), qualified.genericArgumentClause == nil,
                          Self.isSimple(qualified.name.text) {
                    let name = qualified.name.text
                    if qualifier == "Swift", name == "Sendable" {
                        try requireUnshadowed("Swift", at: site)
                        hasSendable = true
                    } else {
                        guard qualifier == module else {
                            throw Self.error(at: site, "Unsupported foreign inherited protocol '\(qualified.trimmedDescription)'. "
                                             + "Supply a same-module protocol")
                        }
                        try requireUnshadowed(qualifier, at: site)
                        try visit(parent(named: name, at: site), referencedAt: site)
                    }
                } else {
                    throw Self.error(at: site, "Unsupported inherited type '\(edge.type.trimmedDescription)'. "
                                     + "Use a simple same-module protocol name or Sendable")
                }
            }
        }

        try visit(root, referencedAt: root.origin)
        guard hasSendable else {
            throw Self.error(at: root.origin, "Use a public Sendable protocol or inherit the standard Sendable marker")
        }
        return resolved
    }

    private func parent(named name: String, at origin: ProtocolSourceOrigin) throws -> IndexedProtocol {
        let candidates = declarationsByName[name, default: []]
        guard !candidates.isEmpty else {
            throw Self.error(at: origin, "Missing inherited protocol \(module).\(name) in the supplied source inputs")
        }
        guard candidates.count == 1, let candidate = candidates.first, !candidate.isConditional else {
            throw Self.error(at: origin, "Ambiguous inherited protocol \(module).\(name); candidates: "
                             + Self.candidateLocations(candidates))
        }
        guard let declaration = candidate.declaration.as(ProtocolDeclSyntax.self) else {
            throw Self.error(at: origin, "Inherited type \(module).\(name) is not a top-level protocol. "
                             + "Declaration: \(candidate.origin)")
        }
        return IndexedProtocol(declaration: declaration, origin: candidate.origin)
    }

    private func requireUnshadowed(_ name: String, at origin: ProtocolSourceOrigin, remedy: String = "") throws {
        guard let candidates = declarationsByName[name], !candidates.isEmpty else { return }
        throw Self.error(at: origin, "Inherited reference '\(name)' is shadowed by a local declaration. Candidates: "
                         + Self.candidateLocations(candidates) + remedy)
    }

    private static func visitTopLevel(
        in statements: CodeBlockItemListSyntax, conditional: Bool = false,
        _ record: (String, DeclSyntax, Bool) -> Void
    ) {
        for statement in statements {
            if let configuration = statement.item.as(IfConfigDeclSyntax.self) {
                for clause in configuration.clauses {
                    if case .statements(let branch)? = clause.elements {
                        visitTopLevel(in: branch, conditional: true, record)
                    }
                }
            } else if let declaration = statement.item.as(DeclSyntax.self),
                      let name = typeName(of: declaration) {
                record(name, declaration, conditional)
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
