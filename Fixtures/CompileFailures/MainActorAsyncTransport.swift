import ConsumerDomain
import ConsumerDoubles

nonisolated func transportOutsideMainActor(_ mock: MainActorDirectoryMock, _ entry: DirectoryEntry) async throws {
    let refreshed = try await mock.refresh(entry)
    entry.name = refreshed.name
}
