import ConsumerDomain
import ConsumerDoubles

nonisolated func offActorSpyCall(_ spy: ActorSpyDirectoryMock, _ entry: ActorSpyEntry) {
    _ = spy.display(entry)
}
