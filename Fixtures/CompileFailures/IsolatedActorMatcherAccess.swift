import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

nonisolated func invalidVerification(_ mock: IsolatedActorDirectoryMock) {
    let matcher = Matcher<IsolatedDirectoryWorker> { worker in worker.count == 1 }
    _ = mock.verify.sample(matcher).wasCalled(.once)
}
