import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import Testing

private typealias RetryEndpoint =
    ProjectedAsyncThrowingEndpoint<RetryScenarioRequest, RetryScenarioReply, RetryScenarioFailure, String, String>

private struct ProjectedRetryRepository: RetryScenarioRepository {
    let endpoint: RetryEndpoint

    func fetch(_ request: RetryScenarioRequest) async throws(RetryScenarioFailure) -> RetryScenarioReply {
        try await endpoint.invoke(request)
    }
}

private actor RetryAnswerGate {
    private let entry: AsyncStream<Bool>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(entry: AsyncStream<Bool>.Continuation) { self.entry = entry }

    func pause() async {
        guard !released else { return }
        // The existing answer stays live after cancellation until the test releases it.
        await withCheckedContinuation { continuation in
            waiter = continuation
            entry.yield(true)
        }
    }

    func release() {
        released = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}

@Test(.timeLimit(.minutes(1)))
func SYS006_concurrentRepositoryRetryComposesProjectionRevisionCancellationAndDeadlines() async throws {
    let session = MockSession()
    let scope = session.makeMock()
    let id = EndpointID("SYS006.repository.fetch")
    let selector = SessionCallSelector(mockID: scope.id, endpoint: id)
    let entry = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let gate = RetryAnswerGate(entry: entry.continuation)
    defer { Task { await gate.release() } }

    let retried = RetryScenarioRequest(id: "retry", authorization: "old-private-authorization")
    let independent = RetryScenarioRequest(id: "fresh", authorization: "new-private-authorization")
    let oldReply = RetryScenarioReply(receipt: "old-accepted", payload: "old-private-payload")
    let newReply = RetryScenarioReply(receipt: "new-accepted", payload: "new-private-payload")
    let setup = AsyncThrowingStubbing<RetryScenarioRequest, RetryScenarioReply, RetryScenarioFailure>()
    setup.matching(Matcher { $0.id == "retry" }).willSequence(
        .throwing(.temporaryUnavailable),
        .answering { request async throws(RetryScenarioFailure) in
            #expect(request.authorization == "old-private-authorization")
            await gate.pause()
            #expect(Task.isCancelled)
            return oldReply
        },
        policy: .finite
    )
    let endpoint = RetryEndpoint(id: id, configuration: setup.finish(),
        projection: InvocationProjection(argument: { $0.id }, result: { $0.receipt }),
        failureReporter: .swiftTesting, scope: scope, failureMapping: { _ in .missingRule })
    let client = RetryScenarioClient(repository: ProjectedRetryRepository(endpoint: endpoint))

    let task = Task {
        defer { entry.continuation.finish() }
        return try await client.load(retried)
    }
    defer { task.cancel() }
    var entries = entry.stream.makeAsyncIterator()
    let entered = await entries.next()
    try #require(entered == true)

    let pending = endpoint.projectedHistory()
    try #require(pending.calls.count == 2)
    let retry = pending.calls[1]
    #expect(pending.calls.map(\.phase) == [.threw, .admitted])
    #expect(pending.calls.map(\.argument) == [.value("retry"), .value("retry")])
    #expect(pending.calls.map(\.result) == [.unavailable, .pending])
    #expect(pending.calls[0].configurationRevision == retry.configurationRevision)
    #expect(session.snapshot().activeInvocationCount == 1)

    let new = AsyncThrowingStubbing<RetryScenarioRequest, RetryScenarioReply, RetryScenarioFailure>()
    new.matching(Matcher { $0.id == "fresh" }).willReturn(newReply)
    let newRevision = endpoint.replaceConfiguration(new.finish())
    #expect(newRevision != retry.configurationRevision)
    let freshReply = try await client.load(independent)
    #expect(freshReply == newReply)
    #expect(session.snapshot().activeInvocationCount == 1)

    task.cancel()
    task.cancel()
    let cancellationCut = session.snapshot()
    let request = try #require(cancellationCut.cancellationRequests.first)
    #expect(cancellationCut.cancellationRequests.count == 1)
    #expect(cancellationCut.activeInvocationCount == 1)
    #expect(request.admission.invocationID == retry.sessionInvocationID)
    #expect(request.admission.configurationRevision == retry.configurationRevision)
    #expect(cancellationCut.events.filter { $0.invocationID == retry.sessionInvocationID }.map(\.phase) == [.admitted])

    await gate.release()
    let obtained = try await task.value
    #expect(obtained == oldReply)
    let history = endpoint.projectedHistory()
    #expect(history.calls.map(\.phase) == [.threw, .returned, .returned])
    #expect(history.calls.map(\.argument) == [.value("retry"), .value("retry"), .value("fresh")])
    #expect(history.calls.map(\.result) == [.unavailable, .value("old-accepted"), .value("new-accepted")])
    #expect(history.calls.map(\.configurationRevision) == [retry.configurationRevision, retry.configurationRevision, newRevision])
    #expect(pending.calls[1].result == .pending)

    let completed = session.snapshot()
    let retryEvents = completed.events.filter { $0.invocationID == retry.sessionInvocationID }
    let terminal = try #require(retryEvents.last)
    #expect(completed.activeInvocationCount == 0)
    #expect(retryEvents.map(\.phase) == [.admitted, .returned])
    #expect(terminal.configurationRevision == retry.configurationRevision)
    #expect(terminal.ordinal > request.ordinal)
    #expect(completed.events.map(\.phase) == [.admitted, .threw, .admitted, .admitted, .returned, .returned])
    #expect(completed.cancellationRequests == [request])

    let stable = try await endpoint.stable(.once, matchingResult: "old-accepted",
                                           for: .milliseconds(1), within: .seconds(2))
    #expect(stable.observed == 1)
    #expect(stable.epoch == history.epoch)
    await #expect(throws: SessionTimedObservationError.deadlineExceeded) {
        try await session.eventually(.exactly(3), for: selector, phase: .returned, within: .milliseconds(20))
    }
}
