import Foundation

/// A mutable domain reference with synchronized reads and writes.
public final class GeneratedProjectionPayload: @unchecked Sendable {
    public let label: String
    private let lock = NSLock()
    private var value: String

    public init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    public func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

public enum GeneratedProjectionFailure: Error {
    case offline
}

public protocol GeneratedProjectionDirectory: Sendable {
    func fetch(id: GeneratedProjectionPayload) async throws(GeneratedProjectionFailure) -> GeneratedProjectionPayload
    func ping() -> String
    func read(id: GeneratedProjectionPayload) -> GeneratedProjectionPayload
}
