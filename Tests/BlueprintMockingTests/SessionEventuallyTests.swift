import Testing
@testable import BlueprintMocking

private func countFixture(in session: MockSession)
    -> (endpoint: SyncEndpoint<String, String>, selector: SessionCallSelector) {
    let scope = session.makeMock()
    let identifier = EndpointID("counted call")
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let endpoint = SyncEndpoint(
        id: identifier, configuration: stubs.finish(), failureReporter: FailureReporter { issue in
            Issue.record("Unexpected issue during count observation: \(issue.message)")
        }, scope: scope
    )
    return (endpoint, SessionCallSelector(mockID: scope.id, endpoint: identifier))
}

@Test func RUN030_exactCountReturnsTheFirstSatisfyingPrefix() async throws {
    let session = MockSession()
    let clock = SessionTestClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    let counted = countFixture(in: session)
    let unrelated = countFixture(in: session)
    let epoch = session.snapshot().epoch
    let waiter = Task {
        try await session.eventually(.exactly(1), for: counted.selector, until: deadline, clock: clock)
    }
    defer { waiter.cancel() }
    await clock.waitUntilTimerRegistered()

    #expect(unrelated.endpoint.invoke("other mock") == "other mock")
    #expect(counted.endpoint.invoke("first") == "first")
    let firstAdmission = try #require(session.snapshot().events.first {
        $0.mockID == counted.selector.mockID && $0.phase == .admitted
    })
    #expect(counted.endpoint.invoke("second") == "second")

    let result = try await waiter.value
    #expect(result.observed == 1)
    #expect(result.epoch == epoch)
    #expect(result.watermark == firstAdmission.ordinal)
    let latest = session.snapshot()
    #expect(latest.watermark > result.watermark)
    #expect(latest.events.filter {
        $0.mockID == counted.selector.mockID && $0.phase == .admitted
    }.count == 2)
}

@Test func RUN030_deadlineAndCancellationResolveIndependently() async throws {
    let session = MockSession()
    let counted = countFixture(in: session)
    let timeoutClock = SessionTestClock()
    let cancellationClock = SessionTestClock()
    let deadline = timeoutClock.now.advanced(by: .seconds(1))
    let cancellationDeadline = cancellationClock.now.advanced(by: .seconds(1))

    let timingOut = Task {
        try await session.eventually(.once, for: counted.selector, until: deadline, clock: timeoutClock)
    }
    let cancelling = Task {
        try await session.eventually(.once, for: counted.selector,
                                     until: cancellationDeadline, clock: cancellationClock)
    }
    defer {
        timingOut.cancel()
        cancelling.cancel()
    }
    await timeoutClock.waitUntilTimerRegistered()
    await cancellationClock.waitUntilTimerRegistered()

    timeoutClock.advance(to: deadline)
    await #expect(throws: SessionCountObservationError.deadlineExceeded) {
        try await timingOut.value
    }
    cancelling.cancel()
    await #expect(throws: CancellationError.self) { try await cancelling.value }
    #expect(session.snapshot().events.isEmpty)
}

@Test func RUN030_resetInvalidatesObservationAndForeignSelectorsAreRejected() async throws {
    let session = MockSession()
    let counted = countFixture(in: session)
    let foreign = countFixture(in: MockSession())
    let clock = SessionTestClock()
    let deadline = clock.now.advanced(by: .seconds(1))

    await #expect(throws: SessionCountObservationError.foreignMock(foreign.selector.mockID)) {
        try await session.eventually(.never, for: foreign.selector, until: deadline, clock: clock)
    }

    let waiter = Task {
        try await session.eventually(.once, for: counted.selector, until: deadline, clock: clock)
    }
    defer { waiter.cancel() }
    await clock.waitUntilTimerRegistered()
    let changed = try session.resetHistory()
    #expect(counted.endpoint.invoke("new epoch") == "new epoch")
    await #expect(throws: SessionCheckpointError.staleEpoch) { try await waiter.value }
    #expect(session.snapshot().epoch == changed)
}

@Test func RUN030_eventualCountsRejectUnavailableHistoryAndImpossiblePredicates() async throws {
    let session = MockSession()
    let counted = countFixture(in: session)
    let clock = SessionTestClock()
    let deadline = clock.now.advanced(by: .seconds(1))

    await #expect(throws: SessionCountObservationError.contradictoryCount) {
        try await session.eventually(.once.and(.never), for: counted.selector,
                                     until: deadline, clock: clock)
    }
    #expect(counted.endpoint.invoke("pruned") == "pruned")
    try session.discardEvents(through: session.checkpoint())
    await #expect(throws: SessionCheckpointError.historyUnavailable) {
        try await session.eventually(.never, for: counted.selector, until: deadline, clock: clock)
    }
    #expect(session.withLock { $0.observationCount } == 0)
}
