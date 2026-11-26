public protocol GenericStaticSubscript: Sendable {
    static subscript<Key: Sendable>(_ key: Key) -> String { get }
}
