public enum RetryScenarioFailure: Error {
    case temporaryUnavailable
    case missingRule
}

public struct RetryScenarioRequest: Sendable {
    public let id: String
    public let authorization: String

    public init(id: String, authorization: String) {
        self.id = id
        self.authorization = authorization
    }
}

public struct RetryScenarioReply: Equatable, Sendable {
    public let receipt: String
    public let payload: String

    public init(receipt: String, payload: String) {
        self.receipt = receipt
        self.payload = payload
    }
}

public protocol RetryScenarioRepository: Sendable {
    func fetch(_ request: RetryScenarioRequest) async throws(RetryScenarioFailure) -> RetryScenarioReply
}

/// Retries one temporary failure through an ordinary injected repository.
public struct RetryScenarioClient: Sendable {
    private let repository: any RetryScenarioRepository

    public init(repository: any RetryScenarioRepository) { self.repository = repository }

    public func load(_ request: RetryScenarioRequest) async throws(RetryScenarioFailure) -> RetryScenarioReply {
        do throws(RetryScenarioFailure) {
            return try await repository.fetch(request)
        } catch {
            guard error == .temporaryUnavailable else { throw error }
        }
        return try await repository.fetch(request)
    }
}
