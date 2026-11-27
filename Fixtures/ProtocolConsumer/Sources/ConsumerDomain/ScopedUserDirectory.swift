public enum ScopedDirectoryError: Error, Sendable {
    case exhausted
}

public protocol ScopedUserDirectory: Sendable {
    func fetch(id: String) async throws(ScopedDirectoryError) -> String
    func label(for id: String) -> String
}
