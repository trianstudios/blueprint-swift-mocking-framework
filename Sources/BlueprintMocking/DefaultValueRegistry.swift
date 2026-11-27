/// A typed factory could not produce the requested default.
public enum DefaultValueResolutionError: Error, Equatable, Sendable {
    case unregistered(typeName: String)
    case cycle(typeNames: [String])
    case depthLimitExceeded(limit: Int, typeNames: [String])

    var diagnostic: String {
        switch self {
        case .unregistered(let typeName):
            "No registered default factory for \(typeName)"
        case .cycle(let typeNames):
            "Default-value cycle: \(typeNames.joined(separator: " -> "))"
        case .depthLimitExceeded(let limit, let typeNames):
            "Default-value depth limit \(limit) exceeded: \(typeNames.joined(separator: " -> "))"
        }
    }
}

private protocol DefaultValueFactory: Sendable {}

private struct TypedDefaultValueFactory<Value: Sendable>: DefaultValueFactory {
    // Retain the result form so published generic storage supports the existing OS floors.
    let make: @Sendable (DefaultValueContext) -> Result<Value, DefaultValueResolutionError>
}

fileprivate struct DefaultValueType: Sendable {
    let identity: ObjectIdentifier
    let name: String
}

/// An immutable set of explicitly registered checked Sendable default factories.
public struct DefaultValueRegistry: Sendable {
    private var factories: [ObjectIdentifier: any DefaultValueFactory] = [:]
    private let maximumDepth: Int

    public init(maximumDepth: Int = 16) {
        precondition(maximumDepth > 0, "Default-value depth must be positive")
        self.maximumDepth = maximumDepth
    }

    /// Returns a new registry that uses this factory for this exact type.
    public func registering<Value: Sendable>(
        _ type: Value.Type,
        factory: @escaping @Sendable (DefaultValueContext) throws(DefaultValueResolutionError) -> Value
    ) -> Self {
        var registered = self
        registered.factories[ObjectIdentifier(type)] = TypedDefaultValueFactory<Value> { context in
            do throws(DefaultValueResolutionError) {
                return .success(try factory(context))
            } catch {
                return .failure(error)
            }
        }
        return registered
    }

    /// Produces a fresh value using the factory for exactly this type.
    public func require<Value: Sendable>(_ type: Value.Type) throws(DefaultValueResolutionError) -> Value {
        try require(type, ancestry: [])
    }

    fileprivate func require<Value: Sendable>(
        _ type: Value.Type, ancestry: [DefaultValueType]
    ) throws(DefaultValueResolutionError) -> Value {
        let entry = DefaultValueType(identity: ObjectIdentifier(type), name: String(reflecting: type))
        let path = ancestry + [entry]
        if ancestry.contains(where: { $0.identity == entry.identity }) {
            throw .cycle(typeNames: path.map(\.name))
        }
        guard path.count <= maximumDepth else {
            throw .depthLimitExceeded(limit: maximumDepth, typeNames: path.map(\.name))
        }
        guard let factory = factories[entry.identity] as? TypedDefaultValueFactory<Value> else {
            throw .unregistered(typeName: entry.name)
        }
        return try factory.make(DefaultValueContext(registry: self, ancestry: path)).get()
    }
}

/// Resolves a factory's default dependencies within the same bounded lookup.
public struct DefaultValueContext: Sendable {
    fileprivate let registry: DefaultValueRegistry
    fileprivate let ancestry: [DefaultValueType]

    public func require<Value: Sendable>(_ type: Value.Type) throws(DefaultValueResolutionError) -> Value {
        try registry.require(type, ancestry: ancestry)
    }
}
