public protocol Lookup: Sendable {
    func lookup(key: String) -> String
}

public struct PhaseDirectory: Sendable {
    private let lookup: any Lookup

    public init(lookup: any Lookup) {
        self.lookup = lookup
    }

    public func label(for key: String) -> String {
        lookup.lookup(key: key)
    }
}
