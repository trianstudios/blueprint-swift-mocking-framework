import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

nonisolated func queryOutsideMainActor(
    _ verification: MainActorDirectoryMock.Verification,
    _ matcher: MainActorMatcher<DirectoryEntry>
) {
    _ = verification.display(matcher)
}
