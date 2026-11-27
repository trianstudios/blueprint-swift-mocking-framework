import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private actor CancellationAnswerGate {
    private let entry: AsyncStream<Bool>.Continuation
    private var held: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(entry: AsyncStream<Bool>.Continuation) {
        self.entry = entry
    }

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            held = continuation
            entry.yield(true)
        }
    }

    func release() {
        isReleased = true
        let pending = held
        held = nil
        pending?.resume()
    }
}

@Test(.timeLimit(.minutes(1)))
func RUN025_cancellationRequestKeepsGeneratedAnswerActiveUntilReturn() async throws {
    try await verifyGeneratedCancellationRequest(detaching: false)
}

@Test(.timeLimit(.minutes(1)))
func RUN025_detachedCancellationRequestStaysWithTypedThrowingAdmission() async throws {
    try await verifyGeneratedCancellationRequest(detaching: true)
}

private func verifyGeneratedCancellationRequest(detaching: Bool) async throws {
    let session = MockSession(clock: .manual)
    let entry = AsyncStream<Bool>.makeStream()
    let gate = CancellationAnswerGate(entry: entry.continuation)
    defer { Task { await gate.release() } }

    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.fetchUser(id: .equal("held")).willAnswer { _ async throws(RepositoryError) in
            await gate.wait()
            if detaching { throw .offline }
            return Task.isCancelled ? "completed after cancellation" : "completed without cancellation"
        }
        stubs.fetchUser(id: .equal("current")).willReturn("current")
    }
    let service = UserService(repository: mock)
    let invocation = Task {
        defer { entry.continuation.finish() }
        return try await service.load(id: "held")
    }
    var entries = entry.stream.makeAsyncIterator()
    let entered = await entries.next()
    try #require(entered == true)

    let admitted = session.snapshot()
    let admission = try #require(admitted.events.first)
    #expect(admitted.events.count == 1)
    #expect(admission.phase == .admitted)
    #expect(admitted.activeInvocationCount == 1)
    #expect(admitted.cancellationRequests.isEmpty)
    let admissionCheckpoint = session.checkpoint()

    if detaching {
        _ = try session.resetHistory(.detachActive)
        #expect(try await service.load(id: "current") == "current")
    }
    let currentBeforeCancellation = session.snapshot()
    let elapsed = Duration.seconds(3)
    try session.advanceClock(by: elapsed)
    invocation.cancel()
    invocation.cancel()

    let pending = try #require(session.snapshot(epoch: admitted.epoch))
    #expect(pending.activeInvocationCount == 1)
    #expect(pending.events == [admission])
    #expect(pending.cancellationRequests.count == 1)
    #expect(pending.cancellationRequestsPrunedThrough == nil)
    let request = try #require(pending.cancellationRequests.first)
    #expect(request.admission == admission)
    #expect(request.elapsed == elapsed)
    #expect(request.ordinal > admission.ordinal)
    #expect(pending.watermark == request.ordinal)
    let requestCheckpoint = session.checkpoint()
    #expect(throws: SessionFinishError.activeInvocations(count: 1)) {
        try session.finishIfQuiescent()
    }

    if detaching {
        let current = session.snapshot()
        #expect(current.epoch != admitted.epoch)
        #expect(current.activeInvocationCount == 0)
        #expect(current.events == currentBeforeCancellation.events)
        #expect(current.cancellationRequests.isEmpty)
    } else {
        #expect(mock.verify.fetchUser(id: .equal("held"), phase: .returned).wasCalled(.never).passed)
        #expect(mock.verify.fetchUser(id: .equal("held"), phase: .threw).wasCalled(.never).passed)
    }

    await gate.release()
    if detaching {
        await #expect(throws: RepositoryError.offline) { try await invocation.value }
    } else {
        let value = try await invocation.value
        #expect(value == "completed after cancellation")
    }

    let completed = try #require(session.snapshot(epoch: admitted.epoch))
    #expect(completed.activeInvocationCount == 0)
    #expect(completed.events.map(\.phase) == [.admitted, detaching ? .threw : .returned])
    #expect(completed.cancellationRequests.map(\.ordinal) == [request.ordinal])
    let terminal = try #require(completed.events.last)
    #expect(terminal.invocationID == admission.invocationID)
    #expect(terminal.epoch == admission.epoch)
    #expect(terminal.configurationRevision == admission.configurationRevision)
    #expect(terminal.ordinal > request.ordinal)

    if detaching {
        let current = session.snapshot()
        #expect(current.events == currentBeforeCancellation.events)
        #expect(current.cancellationRequests.isEmpty)
        #expect(mock.verify.fetchUser(id: .equal("held")).wasCalled(.never).passed)
        #expect(mock.verify.fetchUser(id: .equal("current")).wasCalled(.once).passed)
    } else {
        try session.discardEvents(through: admissionCheckpoint)
        let afterAdmissionPrune = session.snapshot()
        #expect(afterAdmissionPrune.events == [terminal])
        #expect(afterAdmissionPrune.prunedThrough == admission.ordinal)
        #expect(afterAdmissionPrune.cancellationRequests.map(\.admission) == [admission])
        #expect(afterAdmissionPrune.cancellationRequestsPrunedThrough == nil)

        try session.discardEvents(through: requestCheckpoint)
        let afterRequestPrune = session.snapshot()
        #expect(afterRequestPrune.events == [terminal])
        #expect(afterRequestPrune.prunedThrough == admission.ordinal)
        #expect(afterRequestPrune.cancellationRequests.isEmpty)
        #expect(afterRequestPrune.cancellationRequestsPrunedThrough == request.ordinal)
        #expect(try session.events(since: admissionCheckpoint) == [terminal])
        #expect(mock.verify.fetchUser(id: .equal("held"), phase: .returned).wasCalled(.once).passed)
    }
}
