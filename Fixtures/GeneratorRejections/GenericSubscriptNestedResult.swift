public protocol GenericSubscriptNestedResult: Sendable {
    subscript<Key: Sendable>(_ key: Key) -> [Key] { get }
}
