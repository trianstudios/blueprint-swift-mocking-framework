/// Mutable data passed only along the main actor in this fixture.
public final class ActorSpyEntry {
    public var name: String

    public init(_ name: String) {
        self.name = name
    }
}

public enum ActorSpyFailure: Error {
    case unavailable
}

@MainActor
public protocol ActorSpyDirectory {
    func display(_ entry: ActorSpyEntry) -> ActorSpyEntry
    func refresh(_ entry: ActorSpyEntry) async throws(ActorSpyFailure) -> ActorSpyEntry
    func audit(_ entry: ActorSpyEntry)
}

@MainActor
public struct ActorSpyScreen {
    private let directory: any ActorSpyDirectory

    public init(directory: any ActorSpyDirectory) {
        self.directory = directory
    }

    public func display(_ entry: ActorSpyEntry) -> ActorSpyEntry {
        directory.display(entry)
    }

    public func refresh(_ entry: ActorSpyEntry) async throws(ActorSpyFailure) -> ActorSpyEntry {
        try await directory.refresh(entry)
    }
}
