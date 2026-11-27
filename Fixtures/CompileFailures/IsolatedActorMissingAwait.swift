import ConsumerDomain
import ConsumerDoubles

nonisolated func callWithoutIsolationHop(
    _ mock: IsolatedActorDirectoryMock, worker: IsolatedDirectoryWorker
) async -> Int {
    mock.sample(worker)
}
