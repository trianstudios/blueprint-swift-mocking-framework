public enum RepositoryError: Error, Sendable { case offline }

public protocol UserRepository: Sendable {
    func greeting(for name: String) -> String
    func greeting(_ name: String) -> String
    func fetchUser(id: String) async throws(RepositoryError) -> String
}

/// The production module never imports the mocking framework.
public struct UserService: Sendable {
    private let repository: any UserRepository
    public init(repository: any UserRepository) { self.repository = repository }
    public func load(id: String) async throws(RepositoryError) -> String {
        try await repository.fetchUser(id: id)
    }
}

@MainActor public final class UserViewModel {
    private let repository: any UserRepository
    public private(set) var name = ""
    public init(repository: any UserRepository) { self.repository = repository }
    public func load(id: String) async throws(RepositoryError) {
        name = try await repository.fetchUser(id: id)
    }
}
