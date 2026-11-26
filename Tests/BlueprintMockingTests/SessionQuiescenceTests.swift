import Testing
@testable import BlueprintMocking

final class SessionTestClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private let instant = CriticalState(ContinuousClock.now)
    private let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    var now: Instant { instant.withLock { $0 } }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        starts.continuation.yield(())
        starts.continuation.finish()
        var events = updates.stream.makeAsyncIterator()
        while now < deadline {
            _ = await events.next()
            try Task.checkCancellation()
        }
    }

    func waitUntilTimerRegistered() async {
        var events = starts.stream.makeAsyncIterator()
        _ = await events.next()
    }

    func advance(to target: Instant, wakeTimer: Bool = true) {
        instant.withLock { $0 = target }
        if wakeTimer {
            updates.continuation.yield(())
        }
    }
}

private struct HeldSessionCall: Sendable {
    private let entries = AsyncStream<Void>.makeStream()
    private let releases = AsyncStream<Void>.makeStream()
    let endpoint: AsyncEndpoint<String, String>

    init(session: MockSession) {
        let signal = entries.continuation
        let release = releases.stream
        let stubs = AsyncStubbing<String, String>()
        stubs.matching(.any).willAnswer { input in
            signal.yield(())
            signal.finish()
            var gate = release.makeAsyncIterator()
            _ = await gate.next()
            return input
        }
        endpoint = AsyncEndpoint(id: EndpointID("held"), configuration: stubs.finish(),
                                 failureReporter: FailureReporter { _ in }, scope: session.makeMock())
    }

    func waitUntilAdmitted() async {
        var gate = entries.stream.makeAsyncIterator()
        _ = await gate.next()
    }

    func release() {
        releases.continuation.yield(())
        releases.continuation.finish()
    }
}

@Test func RUN035_idleSessionCapturesImmediateZeroSnapshotAndExpiredDeadlineFails() async throws {
    let session = MockSession()
    let clock = SessionTestClock()
    let snapshot = try await session.waitForQuiescence(until: clock.now.advanced(by: .seconds(1)), clock: clock)
    #expect(snapshot == session.snapshot())
    #expect(session.withLock { $0.quiescenceWaiterCount } == 0)

    do {
        _ = try await session.waitForQuiescence(until: clock.now, clock: clock)
        Issue.record("An already expired deadline admitted an observation")
    } catch {
        #expect(error as? SessionQuiescenceError == .deadlineExceeded)
    }
}

@Test func RUN035_quiescenceWaitsForArchivedInvocations() async throws {
    let session = MockSession()
    let held = HeldSessionCall(session: session)
    let invocation = Task { await held.endpoint.invoke("old") }
    await held.waitUntilAdmitted()
    let oldEpoch = session.snapshot().epoch
    let current = try session.resetHistory(.detachActive)
    #expect(session.snapshot().activeInvocationCount == 0)

    let clock = SessionTestClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    let waiter = Task { try await session.waitForQuiescence(until: deadline, clock: clock) }
    await clock.waitUntilTimerRegistered()
    #expect(session.withLock { $0.quiescenceWaiterCount } == 1)
    held.release()

    let snapshot = try await waiter.value
    #expect(await invocation.value == "old")
    #expect(snapshot.epoch == current)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(snapshot.events.isEmpty)
    #expect(session.snapshot(epoch: oldEpoch)?.events.map(\.phase) == [.admitted, .returned])
    #expect(snapshot.watermark == session.snapshot(epoch: oldEpoch)?.events.last?.ordinal)
    #expect(session.withLock { $0.quiescenceWaiterCount } == 0)
}

@Test func RUN035_deadlineAndCancellationRemoveTheirWaiters() async throws {
    let session = MockSession()
    let held = HeldSessionCall(session: session)
    let invocation = Task { await held.endpoint.invoke("held") }
    await held.waitUntilAdmitted()

    let timer = SessionTestClock()
    let timerEnd = timer.now.advanced(by: .seconds(1))
    let timingOut = Task { try await session.waitForQuiescence(until: timerEnd, clock: timer) }
    await timer.waitUntilTimerRegistered()

    let clock = SessionTestClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    let cancelling = Task { try await session.waitForQuiescence(until: deadline, clock: clock) }
    await clock.waitUntilTimerRegistered()
    #expect(session.withLock { $0.quiescenceWaiterCount } == 2)

    let quickStubs = SyncStubbing<String, String>()
    quickStubs.matching(.any).willReturn("ok")
    let quick = SyncEndpoint(id: EndpointID("quick"), configuration: quickStubs.finish(),
                             failureReporter: FailureReporter { _ in }, scope: session.makeMock())
    for _ in 0..<32 {
        #expect(quick.invoke("while waiting") == "ok")
    }
    timer.advance(to: timerEnd)
    do {
        _ = try await timingOut.value
        Issue.record("An active session appeared quiescent at its deadline")
    } catch {
        #expect(error as? SessionQuiescenceError == .deadlineExceeded)
    }
    #expect(session.withLock { $0.quiescenceWaiterCount } == 1)

    cancelling.cancel()
    do {
        _ = try await cancelling.value
        Issue.record("Expected a cancelled wait to throw")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(session.withLock { $0.quiescenceWaiterCount } == 0)
    #expect(session.snapshot().activeInvocationCount == 1)

    held.release()
    _ = await invocation.value
}

@Test func RUN035_lateZeroCannotSucceedWhenTimerTaskHasNotWoken() async throws {
    let session = MockSession()
    let held = HeldSessionCall(session: session)
    let invocation = Task { await held.endpoint.invoke("held") }
    await held.waitUntilAdmitted()

    let clock = SessionTestClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    let waiter = Task { try await session.waitForQuiescence(until: deadline, clock: clock) }
    await clock.waitUntilTimerRegistered()
    clock.advance(to: deadline, wakeTimer: false)
    held.release()

    do {
        _ = try await waiter.value
        Issue.record("A zero observation after the deadline must fail")
    } catch {
        #expect(error as? SessionQuiescenceError == .deadlineExceeded)
    }
    _ = await invocation.value
    #expect(session.withLock { $0.quiescenceWaiterCount } == 0)
}

private func quiescentPlan(returning output: String) -> AsyncThrowingConfiguration<String, String, ServiceError> {
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willReturn(output)
    return stubs.finish()
}

@Test func RUN035_atomicReplacementSucceedsAfterAnActiveSiblingDrains() async throws {
    let session = MockSession()
    let issues = Issues()
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("quiescent-replacement"), configuration: quiescentPlan(returning: "initial"),
        failureReporter: issues.reporter, scope: session.makeMock()
    )
    let held = HeldSessionCall(session: session)
    let invocation = Task { await held.endpoint.invoke("sibling") }
    defer { held.release() }
    await held.waitUntilAdmitted()

    let before = session.snapshot()
    try #require(before.activeInvocationCount == 1)
    try #require(endpoint.invocations.isEmpty)
    let replacement = quiescentPlan(returning: "replacement")
    #expect(throws: QuiescentConfigurationError.activeInvocations(count: 1)) {
        try endpoint.replaceConfigurationIfQuiescent(replacement)
    }
    #expect(session.snapshot() == before)
    #expect(try await endpoint.invoke("still active") == "initial")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [0])

    held.release()
    #expect(await invocation.value == "sibling")
    #expect(session.snapshot().activeInvocationCount == 0)
    let revision = try endpoint.replaceConfigurationIfQuiescent(replacement)
    #expect(revision.rawValue == 1)
    #expect(try await endpoint.invoke("after drain") == "replacement")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [0, 1])
    #expect(issues.values.isEmpty)
}

@Test func RUN035_atomicReplacementCountsInvocationsInDetachedEpochs() async throws {
    let session = MockSession()
    let issues = Issues()
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("replacement-with-archive"), configuration: quiescentPlan(returning: "initial"),
        failureReporter: issues.reporter, scope: session.makeMock()
    )
    let held = HeldSessionCall(session: session)
    let invocation = Task { await held.endpoint.invoke("archived") }
    defer { held.release() }
    await held.waitUntilAdmitted()

    let oldEpoch = session.snapshot().epoch
    let newEpoch = try session.resetHistory(.detachActive)
    let current = session.snapshot()
    try #require(current.epoch == newEpoch)
    try #require(current.activeInvocationCount == 0)
    try #require(session.snapshot(epoch: oldEpoch)?.activeInvocationCount == 1)
    let replacement = quiescentPlan(returning: "replacement")
    #expect(throws: QuiescentConfigurationError.activeInvocations(count: 1)) {
        try endpoint.replaceConfigurationIfQuiescent(replacement)
    }
    #expect(session.snapshot() == current)

    held.release()
    #expect(await invocation.value == "archived")
    #expect(session.snapshot(epoch: oldEpoch)?.events.map(\.phase) == [.admitted, .returned])
    #expect(session.snapshot(epoch: oldEpoch)?.activeInvocationCount == 0)
    let revision = try endpoint.replaceConfigurationIfQuiescent(replacement)
    #expect(revision.rawValue == 1)
    #expect(try await endpoint.invoke("current") == "replacement")
    #expect(session.snapshot().events.map(\.configurationRevision.rawValue) == [1, 1])
    #expect(issues.values.isEmpty)
}

@Test func RUN035_atomicReplacementRefusesStaleAndFinishedScopesWithoutConsumingRevisions() throws {
    let session = MockSession()
    let issues = Issues()
    let initial = quiescentPlan(returning: "initial")
    let replacement = quiescentPlan(returning: "replacement")
    let stale = AsyncThrowingEndpoint(
        id: EndpointID("epoch-bound"), configuration: initial, failureReporter: issues.reporter,
        scope: session.makeEpochBoundMock()
    )
    let live = AsyncThrowingEndpoint(
        id: EndpointID("session-bound"), configuration: initial, failureReporter: issues.reporter,
        scope: session.makeMock()
    )
    try session.resetHistory()

    let before = session.snapshot()
    #expect(throws: QuiescentConfigurationError.staleScope) {
        try stale.replaceConfigurationIfQuiescent(replacement)
    }
    #expect(session.snapshot() == before)
    let finished = try session.finishIfQuiescent()
    #expect(throws: QuiescentConfigurationError.finishedSession) {
        try live.replaceConfigurationIfQuiescent(replacement)
    }
    #expect(session.snapshot() == finished)
    // The existing unrestricted API exposes the next revision without attempting an illegal admission.
    #expect(stale.replaceConfiguration(initial).rawValue == 1)
    #expect(live.replaceConfiguration(initial).rawValue == 1)
    #expect(issues.values.isEmpty)
}

@Test func RUN035_concurrentQuiescentReplacementsPublishUniqueRevisions() async throws {
    let session = MockSession()
    let issues = Issues()
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("competing-replacements"), configuration: quiescentPlan(returning: "initial"),
        failureReporter: issues.reporter, scope: session.makeMock()
    )
    let first = quiescentPlan(returning: "first")
    let second = quiescentPlan(returning: "second")
    async let firstReplacement = endpoint.replaceConfigurationIfQuiescent(first)
    async let secondReplacement = endpoint.replaceConfigurationIfQuiescent(second)
    let (firstRevision, secondRevision) = try await (firstReplacement, secondReplacement)

    #expect(Set([firstRevision.rawValue, secondRevision.rawValue]) == [1, 2])
    let expected = firstRevision.rawValue == 2 ? "first" : "second"
    #expect(try await endpoint.invoke("after both updates") == expected)
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [2])
    #expect(issues.values.isEmpty)
}
