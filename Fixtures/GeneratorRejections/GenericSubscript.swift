public protocol GenericSubscript: Sendable {
    subscript<Key: Hashable & Sendable>(_ key: Key) -> String { get }
}
