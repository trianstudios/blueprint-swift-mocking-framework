public enum PropertyFailure: Error {
    case unavailable
}

public protocol PropertyDirectory: Sendable {
    var title: String { get set }
    var summary: String { get async throws(PropertyFailure) }
}

public struct PropertyScreen: Sendable {
    private var directory: any PropertyDirectory

    public init(directory: any PropertyDirectory) {
        self.directory = directory
    }

    public func title() -> String {
        directory.title
    }

    public mutating func setTitle(_ title: String) {
        directory.title = title
    }

    public func summary() async throws(PropertyFailure) -> String {
        try await directory.summary
    }
}
