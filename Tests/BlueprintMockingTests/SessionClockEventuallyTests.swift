import Testing
@testable import BlueprintMocking

private func clockEventuallyFixture(in session: MockSession)
    -> (endpoint: SyncEndpoint<String, String>, selector: SessionCallSelector) {
    let scope = session.makeMock()
    let id = EndpointID("session-clock count")
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).willAnswer { $0 }
    let endpoint = SyncEndpoint(
        id: id, configuration: setup.finish(), failureReporter: FailureReporter { issue in
            Issue.record("Unexpected issue in session-clock observation: \(issue.message)")
        }, scope: scope
    )
    return (endpoint, SessionCallSelector(mockID: scope.id, endpoint: id))
}

@Test func RUN030_sessionClockKeepsTheFirstPredeadlineMatchAfterDelayedDelivery() async throws {
    let session = MockSession(clock: .manual)
    let counted = clockEventuallyFixture(in: session)
    let wait = try session.prepareTimedCount(.exactly(1), for: counted.selector,
                                             window: .eventually(.seconds(5)))

    try session.advanceClock(by: .seconds(2))
    _ = counted.endpoint.invoke("first")
    let first = try #require(session.snapshot().events.first { $0.phase == .admitted })
    try session.advanceClock(by: .seconds(1))
    _ = counted.endpoint.invoke("invalidates exactly one")
    try session.advanceClock(by: .seconds(5))

    // The reader first runs after the deadline, but both transitions were committed earlier.
    let result = try await wait.value()
    #expect(result.observed == 1)
    #expect(result.elapsed == .seconds(2))
    #expect(result.epoch == first.epoch)
    #expect(result.watermark == first.ordinal)
    #expect(session.snapshot().events.filter { $0.phase == .admitted }.count == 2)
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN030_sessionClockExcludesAnAdmissionStampedExactlyAtTheDeadline() async throws {
    let session = MockSession(clock: .manual)
    let counted = clockEventuallyFixture(in: session)
    let wait = try session.prepareTimedCount(.once, for: counted.selector, window: .eventually(.seconds(5)))

    try session.advanceClock(by: .seconds(5))
    _ = counted.endpoint.invoke("at the exclusive boundary")
    let late = try #require(session.snapshot().events.first)
    #expect(late.elapsed == .seconds(5))

    await #expect(throws: SessionTimedObservationError.deadlineExceeded) { try await wait.value() }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN030_sessionClockOverloadReturnsAnAlreadySatisfyingPrefix() async throws {
    let session = MockSession(clock: .manual)
    let counted = clockEventuallyFixture(in: session)
    try session.advanceClock(by: .seconds(2))
    _ = counted.endpoint.invoke("at registration")
    let before = session.snapshot()

    let result = try await session.eventually(.once, for: counted.selector, phase: .returned, within: .seconds(1))
    #expect(result.observed == 1)
    #expect(result.elapsed == .seconds(2))
    #expect(result.epoch == before.epoch)
    #expect(result.watermark == before.watermark)
    #expect(session.withLock { $0.observationCount } == 0)
    await #expect(throws: SessionTimedObservationError.invalidDuration) {
        try await session.eventually(.once, for: counted.selector, within: .zero)
    }
}

@Test func RUN030_sessionClockRejectsHistoryLossAndUnregisters() async throws {
    let session = MockSession(clock: .manual)
    let counted = clockEventuallyFixture(in: session)
    let wait = try session.prepareTimedCount(.once, for: counted.selector, window: .eventually(.seconds(5)))

    _ = counted.endpoint.invoke("unread match")
    try session.discardEvents(through: session.checkpoint())
    try session.advanceClock(by: .seconds(6))

    await #expect(throws: SessionCheckpointError.historyUnavailable) { try await wait.value() }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN030_sessionClockCancellationUnregisters() async throws {
    let session = MockSession(clock: .manual)
    let counted = clockEventuallyFixture(in: session)
    let wait = try session.prepareTimedCount(.once, for: counted.selector, window: .eventually(.seconds(5)))
    #expect(session.withLock { $0.observationCount } == 1)

    let task = Task { try await wait.value() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(session.withLock { $0.observationCount } == 0)
}
