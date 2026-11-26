import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

nonisolated func configureOutsideMainActor(
    _ stubs: MainActorDirectoryMock.Stubs,
    _ matcher: MainActorMatcher<DirectoryEntry>
) {
    _ = stubs.display(matcher)
}
