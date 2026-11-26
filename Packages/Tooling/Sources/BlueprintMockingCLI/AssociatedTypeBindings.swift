import Foundation
import SwiftSyntax

struct AssociatedTypeBinding: Codable {
    let name: String
    let type: String
}

extension AssociatedTypeBinding {
    init?(argument: String) {
        let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(name: String(parts[0]), type: String(parts[1]))
    }
}

struct ConcreteAssociatedTypeBindings {
    let types: [String: String]
    private let visibleNames: [SyntaxIdentifier: Set<String>]

    init(
        options: [AssociatedTypeBinding],
        root: IndexedProtocol,
        inheritance: ResolvedProtocolInheritance,
        index: ProtocolSourceIndex
    ) throws {
        func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
            throw GenerationError(description: "\(index.origin(of: node)): error: BPM001: \(message)")
        }

        let declarations = inheritance.declarations
        let associatedDeclarations = declarations.flatMap { declaration in
            declaration.declaration.memberBlock.members.compactMap { item in
                item.decl.as(AssociatedTypeDeclSyntax.self).map { (declaration.declaration.id, $0) }
            }
        }
        let usesPrimaryTypes = declarations.contains { $0.declaration.primaryAssociatedTypeClause != nil }
        guard !options.isEmpty || !associatedDeclarations.isEmpty || usesPrimaryTypes else {
            types = [:]
            visibleNames = [:]
            return
        }

        if declarations.contains(where: { $0.origin.module != root.origin.module }) {
            try reject(root.declaration, "Cross-module associated-type bindings require compiler-backed type resolution")
        }
        guard root.declaration.attributes.isEmpty else {
            try reject(root.declaration, "Concrete associated-type bindings require a Sendable protocol")
        }
        guard index.isUnshadowed("Swift", in: root.origin.module) else {
            try reject(root.declaration, "Concrete associated-type bindings need an unshadowed Swift module")
        }

        var associatedByName: [String: AssociatedTypeDeclSyntax] = [:]
        var ownNames: [SyntaxIdentifier: Set<String>] = [:]
        let helperNames: Set<String> = [
            "Self", "Swift", "Sendable", "Void", "Never", "Error", "BlueprintMocking",
            "BlueprintRuntimeSchemaV1", "MockSession", "FailureReporter", "MockIssue", "EndpointID",
            "SourceLocation", "Matcher", "CallPhase", "Stubs", "Verification", "FailureMappings",
            root.name, root.name + "Mock",
        ]
        let runtimeNames = Set(["Sync", "Async", "SyncThrowing", "AsyncThrowing"].flatMap { family in
            ["Endpoint", "Stubbing", "Stub"].map { family + $0 }
        })
        let reservedNames = helperNames.union(runtimeNames)
        for (id, associated) in associatedDeclarations {
            let name = associated.name.text
            guard Self.isSimple(name), !reservedNames.contains(name) else {
                try reject(associated, "Associated type '\(name)' conflicts with a generated witness name or is unsupported")
            }
            let constraints = associated.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            guard associated.attributes.isEmpty, associated.modifiers.isEmpty, associated.initializer == nil,
                  associated.genericWhereClause == nil,
                  constraints.isEmpty || constraints == ["Sendable"] || constraints == ["Swift.Sendable"] else {
                try reject(associated, "Concrete associated-type bindings support only an optional Sendable constraint, without defaults or where clauses")
            }
            if let constraint = constraints.first {
                try index.requireUnshadowedQualifier(constraint == "Sendable" ? "Sendable" : "Swift", at: associated)
            }
            if let previous = associatedByName[name] {
                try reject(associated, "Ambiguous redeclaration of associated type '\(name)' (previous declaration at \(index.origin(of: previous)))")
            }
            associatedByName[name] = associated
            ownNames[id, default: []].insert(name)
        }

        var visible: [SyntaxIdentifier: Set<String>] = [:]
        func namesVisible(in id: SyntaxIdentifier) -> Set<String> {
            if let cached = visible[id] { return cached }
            let names = inheritance.parentsByDeclaration[id, default: []].reduce(into: ownNames[id, default: []]) {
                $0.formUnion(namesVisible(in: $1))
            }
            visible[id] = names
            return names
        }
        for entry in declarations {
            let names = namesVisible(in: entry.declaration.id)
            for primary in entry.declaration.primaryAssociatedTypeClause?.primaryAssociatedTypes ?? [] {
                guard names.contains(primary.name.text) else {
                    try reject(primary, "Primary associated type '\(primary.name.text)' must name a visible associated type")
                }
            }
        }
        visibleNames = visible

        var concrete: [String: String] = [:]
        for option in options {
            let name = option.name.trimmingCharacters(in: .whitespaces)
            let spelling = option.type.trimmingCharacters(in: .whitespaces)
            guard Self.isSimple(name), let associated = associatedByName[name] else {
                try reject(root.declaration, "Unknown associated type '\(name)'")
            }
            let scalar = spelling.hasPrefix("Swift.") ? String(spelling.dropFirst("Swift.".count)) : spelling
            guard ["Bool", "Int", "String"].contains(scalar) else {
                try reject(associated, "Unsupported concrete associated type binding for '\(name)'. Use Swift.Bool, Swift.Int or Swift.String")
            }
            let canonical = "Swift.\(scalar)"
            if let previous = concrete[name] {
                let reason = previous == canonical ? "Duplicate" : "Conflicting"
                try reject(associated, "\(reason) explicit bindings for associated type '\(name)'")
            }
            concrete[name] = canonical
        }
        for (name, associated) in associatedByName.sorted(by: { $0.key < $1.key }) where concrete[name] == nil {
            try reject(associated, "Missing explicit binding for associated type '\(name)'")
        }
        types = concrete
    }

    func resolve(_ identifier: IdentifierTypeSyntax) -> String? {
        let name = identifier.name.text
        guard let bound = types[name] else { return name }

        // A declaration on a separate inheritance branch cannot see a child's associated type.
        // Emitting that bare name would also capture it with the generated typealias.
        var ancestor = identifier.parent
        while let syntax = ancestor {
            if syntax.is(ProtocolDeclSyntax.self) {
                return visibleNames[syntax.id]?.contains(name) == true ? bound : nil
            }
            ancestor = syntax.parent
        }
        return nil
    }

    private static func isSimple(_ name: String) -> Bool {
        name.first?.isLetter == true
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
