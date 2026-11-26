public enum DepthSpyFailure: Error {
    case forwardingLimit
    case fixtureEscape
}

public protocol DepthSpyDirectory: Sendable {
    func fetch(_ value: Int) async throws(DepthSpyFailure) -> Int
}

public struct DepthSpyClient: Sendable {
    private let directory: any DepthSpyDirectory

    public init(directory: any DepthSpyDirectory) {
        self.directory = directory
    }

    public func fetch(_ value: Int) async throws(DepthSpyFailure) -> Int {
        try await directory.fetch(value)
    }
}
