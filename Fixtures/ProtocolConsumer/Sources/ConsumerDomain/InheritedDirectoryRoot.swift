public enum InheritedDirectoryFailure: Error, Equatable {
    case offline
}

public protocol InheritedDirectoryRoot: Sendable {
    func label(for key: String) -> String
    func fetch(id: Int) async throws(InheritedDirectoryFailure) -> String
    func mark(_ detail: String)
}
