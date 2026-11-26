public enum VariadicSubscriptFailure: Error {
    case unavailable
}

public protocol VariadicSubscriptDirectory: Sendable {
    subscript(field field: String, _ indices: Int...) -> String { get set }
    subscript(remote region: String, _ indices: Int...) -> String { get async throws(VariadicSubscriptFailure) }
}

public struct VariadicSubscriptClient: Sendable {
    private var directory: any VariadicSubscriptDirectory

    public init(directory: any VariadicSubscriptDirectory) {
        self.directory = directory
    }

    public func emptyLabel() -> String {
        directory[field: "title"]
    }

    public mutating func storeEmptyLabel() {
        directory[field: "title"] = "inbox"
    }

    public mutating func reviseOrderedLabel() {
        directory[field: "title", 4, 2, 4] += "!"
    }

    public func remoteNames() async throws(VariadicSubscriptFailure) -> String {
        try await directory[remote: "east", 6, 3, 6]
    }

    public func remoteWithoutIndices() async throws(VariadicSubscriptFailure) -> String {
        try await directory[remote: "east"]
    }
}
