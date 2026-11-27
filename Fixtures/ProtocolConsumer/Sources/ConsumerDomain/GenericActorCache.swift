public protocol GenericActorCache<Value>: Sendable {
    associatedtype Value: Sendable
    func lookup<Key: Hashable & Sendable>(_ key: Key) async -> Value?
}

public actor IsolatedStringCache: GenericActorCache {
    public typealias Value = String

    private var entries: [AnyHashable: String] = [:]
    public private(set) var reads: [String] = []

    public init() {}

    public func store<Key: Hashable & Sendable>(_ value: String, for key: Key) {
        entries[AnyHashable(key)] = value
    }

    public func lookup<Key: Hashable & Sendable>(_ key: Key) async -> String? {
        reads.append("\(String(reflecting: Key.self)):\(key)")
        return entries[AnyHashable(key)]
    }
}
