import BlueprintMocking
import ConsumerDomain

nonisolated func verifyOutsideMainActor(_ query: MainActorVerification<DirectoryEntry>) {
    _ = query.wasCalled(.once)
}
