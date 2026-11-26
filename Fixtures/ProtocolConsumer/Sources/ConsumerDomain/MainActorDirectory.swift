/// Mutable reference data deliberately confined to its consuming actor.
public final class DirectoryEntry {
    public var name: String

    public init(_ name: String) {
        self.name = name
    }
}

public enum DirectoryFailure: Error {
    case unavailable
}

@MainActor
public protocol MainActorDirectory {
    func display(_ entry: DirectoryEntry) -> DirectoryEntry
    func refresh(_ entry: DirectoryEntry) async throws(DirectoryFailure) -> DirectoryEntry
    func require(_ entry: DirectoryEntry) throws(DirectoryFailure) -> DirectoryEntry
    func read(_ entry: DirectoryEntry) async -> DirectoryEntry
    func audit(_ entry: DirectoryEntry)
}

@MainActor
public struct DirectoryScreen {
    private let directory: any MainActorDirectory

    public init(directory: any MainActorDirectory) {
        self.directory = directory
    }

    public func display(_ entry: DirectoryEntry) -> DirectoryEntry {
        directory.display(entry)
    }

    public func refresh(_ entry: DirectoryEntry) async throws(DirectoryFailure) -> DirectoryEntry {
        try await directory.refresh(entry)
    }
}
