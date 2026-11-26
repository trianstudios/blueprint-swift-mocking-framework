/// A production dependency with one requirement for each standard effect shape.
public protocol EffectDirectory: Sendable {
    func localName(id: String) -> String
    func cachedName(id: String) throws -> String
    func refreshedName(id: String) async -> String
    func remoteName(id: String) async throws -> String
}

/// A real caller with no mocking dependency.
public struct DirectoryLoader: Sendable {
    private let directory: any EffectDirectory

    public init(directory: any EffectDirectory) {
        self.directory = directory
    }

    public func load(id: String) async throws -> [String] {
        let local = directory.localName(id: id)
        let cached = try directory.cachedName(id: id)
        let refreshed = await directory.refreshedName(id: id)
        let remote = try await directory.remoteName(id: id)
        return [local, cached, refreshed, remote]
    }
}
