public enum InoutSpyFailure: Error {
    case afterMutation
    case stubbed
}

public protocol InoutSpyDirectory: Sendable {
    func adjust(_ value: inout Int) throws(InoutSpyFailure) -> Int
    func normalize(_ value: inout Int)
}

public struct InoutSpyClient {
    private let directory: any InoutSpyDirectory

    public init(directory: any InoutSpyDirectory) {
        self.directory = directory
    }

    public func adjust(_ value: inout Int) throws(InoutSpyFailure) -> Int {
        try directory.adjust(&value)
    }

    public func normalize(_ value: inout Int) {
        directory.normalize(&value)
    }
}

public enum OrdinaryInoutFailure: Error, Sendable {
    case afterMutation
}

public protocol OrdinaryInoutDirectory: Sendable {
    func adjust(_ value: inout Swift.Int) throws(OrdinaryInoutFailure) -> Int
    func normalize(_ value: inout Swift.Int)
}
