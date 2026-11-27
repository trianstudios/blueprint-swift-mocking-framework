import Testing
@testable import BlueprintMocking

private enum DelayedSequenceFixtureError: Error {
    case cancelled
    case registrationNotObserved
}

private func delayedSequenceEndpoint(_ session: MockSession)
    -> AsyncThrowingEndpoint<String, String, DelayedSequenceFixtureError> {
    let setup = AsyncThrowingStubbing<String, String, DelayedSequenceFixtureError>()
    setup.matching(.any).willSequence(
        .returning("delayed", after: .seconds(2), onCancellation: .cancelled),
        .returning("next")
    )
    return AsyncThrowingEndpoint(id: EndpointID("delay"), configuration: setup.finish(),
        failureReporter: FailureReporter { _ in Issue.record("Unexpected delayed sequence issue") },
        scope: session.makeMock())
}

private func waitForDelayedAnswer(in session: MockSession) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while session.withLock({ $0.delayedAnswerWaiterCount }) != 1 {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DelayedSequenceFixtureError.registrationNotObserved }
        await Task.yield()
    }
}

@Test(.timeLimit(.minutes(1)))
func RUN024_delayedSequenceResumesAtExactManualDeadline() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = delayedSequenceEndpoint(session)
    try session.advanceClock(by: .seconds(20))
    let first = Task { try await endpoint.invoke("first") }
    defer { first.cancel() }
    try await waitForDelayedAnswer(in: session)

    let admission = try #require(session.snapshot().events.first)
    #expect(admission.phase == .admitted)
    #expect(try await endpoint.invoke("second") == "next")
    try session.advanceClock(by: .seconds(2) - .nanoseconds(1))
    #expect(session.withLock { $0.delayedAnswerWaiterCount } == 1)
    #expect(session.snapshot().activeInvocationCount == 1)
    #expect(session.snapshot().events.filter { $0.invocationID == admission.invocationID } == [admission])

    try session.advanceClock(by: .nanoseconds(1))
    #expect(try await first.value == "delayed")
    #expect(session.withLock { $0.delayedAnswerWaiterCount } == 0)
    let completed = session.snapshot().events.filter { $0.invocationID == admission.invocationID }
    #expect(completed.map(\.phase) == [.admitted, .returned])
    #expect(completed.last?.elapsed == .seconds(22))
    #expect(session.snapshot().activeInvocationCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func RUN024_delayedSequenceCancellationKeepsDetachedAdmissionAndConsumesStep() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = delayedSequenceEndpoint(session)
    let first = Task { try await endpoint.invoke("first") }
    defer { first.cancel() }
    try await waitForDelayedAnswer(in: session)

    let admission = try #require(session.snapshot().events.first)
    _ = try session.resetHistory(.detachActive)
    #expect(session.withLock { $0.delayedAnswerWaiterCount } == 1)
    #expect(throws: SessionFinishError.activeInvocations(count: 1)) { try session.finishIfQuiescent() }
    #expect(try await endpoint.invoke("second") == "next")
    try session.advanceClock(by: .seconds(1))
    first.cancel()
    first.cancel()
    await #expect(throws: DelayedSequenceFixtureError.cancelled) { try await first.value }
    #expect(session.withLock { $0.delayedAnswerWaiterCount } == 0)

    let archived = try #require(session.snapshot(epoch: admission.epoch))
    #expect(archived.events.map(\.phase) == [.admitted, .threw])
    #expect(archived.activeInvocationCount == 0)
    #expect(archived.cancellationRequests.count == 1)
    let request = try #require(archived.cancellationRequests.first)
    let terminal = try #require(archived.events.last)
    #expect(request.admission == admission)
    #expect(request.ordinal < terminal.ordinal)
    #expect(terminal.invocationID == admission.invocationID)
    #expect(terminal.elapsed == .seconds(1))
    #expect(session.snapshot().cancellationRequests.isEmpty)

    try session.advanceClock(by: .seconds(2))
    #expect(session.snapshot(epoch: admission.epoch)?.events == archived.events)
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned])
}

@Test(.timeLimit(.minutes(1)))
func RUN024_delayedSequenceContinuousClockWakesInvocation() async throws {
    let session = MockSession()
    let setup = AsyncThrowingStubbing<String, String, DelayedSequenceFixtureError>()
    setup.matching(.any).willSequence(.returning("delayed", after: .milliseconds(10), onCancellation: .cancelled))
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("continuous delay"), configuration: setup.finish(),
        failureReporter: FailureReporter { _ in Issue.record("Unexpected delayed sequence issue") },
        scope: session.makeMock())

    #expect(try await endpoint.invoke("first") == "delayed")
    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned])
    let admission = try #require(events.first)
    let terminal = try #require(events.last)
    #expect(terminal.elapsed - admission.elapsed >= .milliseconds(10))
    #expect(session.withLock { $0.delayedAnswerWaiterCount } == 0)
}
