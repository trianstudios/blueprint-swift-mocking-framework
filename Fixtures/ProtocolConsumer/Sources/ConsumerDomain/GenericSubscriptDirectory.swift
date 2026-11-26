public protocol GenericSubscriptDirectory: Sendable {
    subscript<Key: Hashable & Sendable>(_ key: Key) -> Key { get }
    subscript<Key: Sendable>(named key: Key) -> String { get }
}

public struct GenericSubscriptClient: Sendable {
    private let directory: any GenericSubscriptDirectory

    public init(directory: any GenericSubscriptDirectory) {
        self.directory = directory
    }

    public func read<Key: Hashable & Sendable>(_ key: Key) -> Key {
        directory[key]
    }

    public func name<Key: Sendable>(for key: Key) -> String {
        directory[named: key]
    }
}
