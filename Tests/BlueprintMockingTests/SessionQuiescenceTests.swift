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
