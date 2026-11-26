import ConsumerDomain
import ConsumerDoubles

nonisolated func callWitnessOutsideMainActor(_ mock: MainActorDirectoryMock, _ entry: DirectoryEntry) {
    _ = mock.display(entry)
}
