public extension DefaultValueRegistry {
    /// Creates a registry for `Bool` (`false`), `Int` (`0`), and the empty `String`.
    static func safePrimitives(maximumDepth: Int = 16) -> Self {
        Self(maximumDepth: maximumDepth)
            .registering(Bool.self) { _ in false }
            .registering(Int.self) { _ in 0 }
            .registering(String.self) { _ in "" }
    }

    /// Registers a nil result for this exact optional type.
    func registeringNil<Wrapped: Sendable>(_ type: Optional<Wrapped>.Type) -> Self {
        registering(type) { _ in nil }
    }

    /// Registers an empty result for this exact array type.
    func registeringEmpty<Element: Sendable>(_ type: [Element].Type) -> Self {
        registering(type) { _ in [] }
    }

    /// Registers an empty result for this exact dictionary type.
    func registeringEmpty<Key: Hashable & Sendable, Value: Sendable>(_ type: [Key: Value].Type) -> Self {
        registering(type) { _ in [:] }
    }

    /// Registers an empty result for this exact set type.
    func registeringEmpty<Element: Hashable & Sendable>(_ type: Set<Element>.Type) -> Self {
        registering(type) { _ in [] }
    }
}
