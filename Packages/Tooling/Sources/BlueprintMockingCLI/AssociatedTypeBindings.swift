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

private struct IteratorElementConstraint {
    let requirement: SameTypeRequirementSyntax
    let scope: SyntaxIdentifier
    let elementName: String

    init?(_ associated: AssociatedTypeDeclSyntax, scope: SyntaxIdentifier) {
        guard let requirements = associated.genericWhereClause?.requirements, requirements.count == 1,
              let requirement = requirements.first,
              let equality = Syntax(requirement.requirement).as(SameTypeRequirementSyntax.self),
              let member = Syntax(equality.leftType).as(MemberTypeSyntax.self),
              member.name.text == "Element", member.genericArgumentClause == nil,
              let base = member.baseType.as(IdentifierTypeSyntax.self),
              base.name.text == associated.name.text, base.genericArgumentClause == nil,
              let element = Syntax(equality.rightType).as(IdentifierTypeSyntax.self),
              element.genericArgumentClause == nil else { return nil }
        self.requirement = equality
        self.scope = scope
        elementName = element.name.text
    }
}

struct ConcreteAssociatedTypeBindings {
    let types: [String: String]
    private let visibleNames: [SyntaxIdentifier: Set<String>]
    private static let supportedScalars: Set<String> = ["Swift.Bool", "Swift.Int", "Swift.String"]

    init(
        options: [AssociatedTypeBinding],
        root: IndexedProtocol,
        inheritance: ResolvedProtocolInheritance,
        activeMembers: [(declarationID: SyntaxIdentifier, items: [MemberBlockItemSyntax])],
        index: ProtocolSourceIndex
    ) throws {
        func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
            throw GenerationError(description: "\(index.origin(of: node)): error: BPM001: \(message)")
        }

        let declarations = inheritance.declarations
        let associatedDeclarations = activeMembers.flatMap { entry in
            entry.items.compactMap { item in
                item.decl.as(AssociatedTypeDeclSyntax.self).map { (entry.declarationID, $0) }
            }
        }
        let usesPrimaryTypes = declarations.contains { $0.declaration.primaryAssociatedTypeClause != nil }
        guard !options.isEmpty || !associatedDeclarations.isEmpty || usesPrimaryTypes else {
            types = [:]
            visibleNames = [:]
            return
        }

        guard root.declaration.attributes.isEmpty else {
            try reject(root.declaration, "Concrete associated-type bindings require a Sendable protocol")
        }
        guard index.isUnshadowed("Swift", in: root.origin.module) else {
            try reject(root.declaration, "Concrete associated-type bindings need an unshadowed Swift module")
        }

        var associatedByName: [String: AssociatedTypeDeclSyntax] = [:]
        var ownNames: [SyntaxIdentifier: Set<String>] = [:]
        var iteratorConstraints: [String: IteratorElementConstraint] = [:]
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
            let constraints = associated.inheritanceClause?.inheritedTypes.flatMap { entry in
                if let composition = entry.type.as(CompositionTypeSyntax.self) {
                    return composition.elements.map { $0.type.trimmedDescription }
                }
                return [entry.type.trimmedDescription]
            } ?? []
            let iterator = constraints.sorted() == ["Swift.IteratorProtocol", "Swift.Sendable"]
            let simple = associated.genericWhereClause == nil
                && (constraints.isEmpty || constraints == ["Sendable"] || constraints == ["Swift.Sendable"])
            guard associated.attributes.isEmpty, associated.modifiers.isEmpty, associated.initializer == nil,
                  iterator || simple else {
                try reject(associated, "Concrete associated-type bindings support only an optional Sendable constraint, without defaults or where clauses, or a supplied iterator with a supported element equality")
            }
            if iterator {
                guard let requirement = IteratorElementConstraint(associated, scope: id) else {
                    try reject(associated, "A dependent iterator requires one equality of its Element with a visible associated type")
                }
                iteratorConstraints[name] = requirement
                try index.requireUnshadowedQualifier("Swift", at: associated)
            } else if let constraint = constraints.first {
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
        if !iteratorConstraints.isEmpty, let shadow = associatedByName[root.origin.module] {
            try reject(shadow, "The associated type name shadows the module used for the concrete iterator binding")
        }
        let iteratorRequirements = iteratorConstraints.sorted { $0.key < $1.key }
        if let constraint = iteratorRequirements.first?.value, reservedNames.contains(root.origin.module) {
            try reject(constraint.requirement, "Dependent iterator binding cannot use module '\(root.origin.module)' because that name is used by the generated mock.")
        }
        for (_, constraint) in iteratorRequirements {
            guard visible[constraint.scope]?.contains(constraint.elementName) == true else {
                try reject(constraint.requirement, "Iterator element equality must reference an associated type visible in the declaring protocol")
            }
        }

        var inheritedByName: [String: InheritedPrimaryTypeBinding] = [:]
        for binding in inheritance.primaryTypeBindings {
            if let previous = inheritedByName[binding.name] {
                guard previous.type == binding.type else {
                    throw GenerationError(description: "\(binding.origin): error: BPM001: Conflicting inherited specializations for "
                                          + "'\(binding.name)' require \(previous.type) at \(previous.origin) and \(binding.type)")
                }
            } else {
                inheritedByName[binding.name] = binding
            }
        }

        var concrete: [String: String] = [:]
        for option in options {
            let name = option.name.trimmingCharacters(in: .whitespaces)
            let spelling = option.type.trimmingCharacters(in: .whitespaces)
            guard Self.isSimple(name), let associated = associatedByName[name] else {
                try reject(root.declaration, "Unknown associated type '\(name)'")
            }
            let canonical: String
            if iteratorConstraints[name] != nil {
                canonical = spelling
            } else {
                canonical = spelling.hasPrefix("Swift.") ? spelling : "Swift.\(spelling)"
                guard Self.supportedScalars.contains(canonical) else {
                    try reject(associated, "Unsupported concrete associated type binding for '\(name)'. Use Swift.Bool, Swift.Int or Swift.String")
                }
            }
            if let previous = concrete[name] {
                let reason = previous == canonical ? "Duplicate" : "Conflicting"
                try reject(associated, "\(reason) explicit bindings for associated type '\(name)'")
            }
            if let required = inheritedByName[name], canonical != required.type {
                throw GenerationError(description: "\(required.origin): error: BPM001: Inherited specialization for '\(name)' "
                                      + "requires \(required.type), but the explicit binding is \(canonical)")
            }
            concrete[name] = canonical
        }
        for binding in inheritedByName.values {
            concrete[binding.name] = binding.type
        }
        for (name, associated) in associatedByName.sorted(by: { $0.key < $1.key }) where concrete[name] == nil {
            try reject(associated, "Missing explicit binding for associated type '\(name)'")
        }
        for (iteratorName, constraint) in iteratorRequirements {
            let module = root.origin.module
            let typeName = concrete[iteratorName] ?? ""
            let parts = typeName.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == module, Self.isSimple(String(parts[1])) else {
                try reject(constraint.requirement, "Dependent iterator binding '\(iteratorName)' requires a module-qualified struct in \(module)")
            }
            guard let expected = concrete[constraint.elementName], Self.supportedScalars.contains(expected) else {
                try reject(constraint.requirement, "Iterator element equality requires a concrete Swift scalar binding for '\(constraint.elementName)'")
            }
            let evidence = try index.iteratorElementWitness(named: String(parts[1]), in: module, at: constraint.requirement)
            guard evidence.type == expected else {
                let equality = "\(iteratorName).Element == \(constraint.elementName)"
                try reject(constraint.requirement,
                           "Dependent same-type constraint '\(equality)' requires matching types. "
                           + "\(typeName).Element is \(evidence.type) at \(evidence.origin) and \(constraint.elementName) is \(expected)")
            }
        }
        types = concrete
    }

    func resolve(_ identifier: IdentifierTypeSyntax) -> String? {
        let name = identifier.name.text
        return types[name] == nil ? name : boundType(for: identifier)
    }

    func boundType(for identifier: IdentifierTypeSyntax) -> String? {
        let name = identifier.name.text
        guard identifier.genericArgumentClause == nil, let bound = types[name] else { return nil }

        // Only declarations that inherit or declare this associated type can use its binding.
        // Emitting a bare nominal name from another branch could capture the mock's typealias.
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
