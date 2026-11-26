public protocol GenericSubscriptSetter: Sendable {
    subscript<Key: Sendable>(_ key: Key) -> String { get set }
}
