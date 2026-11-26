import ConsumerDomain
import ConsumerDoubles

nonisolated func offActorSpyTransfer(_ spy: ActorSpyDirectoryMock, _ entry: ActorSpyEntry) async throws {
    let output = try await spy.refresh(entry)
    entry.name = output.name
}
