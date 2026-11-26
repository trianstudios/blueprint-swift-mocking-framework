public struct LookupRecord: Sendable, Equatable {
    public let id: Int
    public let namespace: String

    public init(id: Int, namespace: String) {
        self.id = id
        self.namespace = namespace
    }
}

public protocol LookupParameters: Sendable {
    func next() -> String
    func lookup(namespace: String, _ key: String) -> String
    func lookup(namespace: String, id: Int) -> LookupRecord
}

public struct LookupClient: Sendable {
    private let lookup: any LookupParameters
    public init(lookup: any LookupParameters) { self.lookup = lookup }
    public func label(for key: String) -> String {
        let namespace = lookup.next()
        return lookup.lookup(namespace: namespace, key)
    }
}
