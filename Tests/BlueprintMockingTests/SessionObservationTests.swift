import Testing
@testable import BlueprintMocking

private func observedEndpoint(_ session: MockSession) -> SyncEndpoint<String, String> {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    return SyncEndpoint(id: EndpointID("observed"), configuration: stubs.finish(),
                        failureReporter: FailureReporter { _ in }, scope: session.makeMock())
}

@Test func RUN033_oneWakeReplaysBothTransitionsWhileTheReaderWasPaused() async throws {
    let session = MockSession()
    let endpoint = observedEndpoint(session)
    let lease = session.observeChanges()
    #expect(lease.initialSnapshot.activeInvocationCount == 0)
    #expect(lease.checkpoint.watermark == lease.initialSnapshot.watermark)
    #expect(lease.checkpoint.epoch == lease.initialSnapshot.epoch)

    // The entire call happens before the observer creates an iterator.
    #expect(endpoint.invoke("one") == "one")
    var iterator = lease.notifications.makeAsyncIterator()
    #expect(await iterator.next() != nil)

    let first = try session.replay(since: lease.checkpoint)
    #expect(first.events.map(\.phase) == [.admitted, .returned])
    #expect(first.events[0].invocationID == first.events[1].invocationID)
    var active = lease.initialSnapshot.activeInvocationCount
    var zero = [active == 0]
    var wholeIntervalHeld = active == 0
    var stableStart: UInt64? = lease.checkpoint.watermark
    for event in first.events {
        active += event.phase == .admitted ? 1 : -1
        zero.append(active == 0)
        if active == 0 {
            if stableStart == nil { stableStart = event.ordinal }
        } else {
            wholeIntervalHeld = false
            stableStart = nil
        }
    }
    #expect(zero == [true, false, true])
    #expect(!wholeIntervalHeld)
    #expect(stableStart == first.events.last?.ordinal)

    // Arrives after replay returns but before the reader advances to its returned cursor.
    #expect(endpoint.invoke("two") == "two")
    #expect(await iterator.next() != nil)
    let second = try session.replay(since: first.checkpoint)
    #expect(second.events.map(\.phase) == [.admitted, .returned])
    #expect(second.events.allSatisfy { $0.ordinal > first.checkpoint.watermark })
    #expect(Set(second.events.map(\.invocationID)).isDisjoint(with: first.events.map(\.invocationID)))

    lease.cancel()
    #expect(await iterator.next() == nil)
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN033_resetAndFinishWakeAndCloseTheirLeases() async throws {
    let session = MockSession()
    let beforeReset = session.observeChanges()
    var resetIterator = beforeReset.notifications.makeAsyncIterator()

    let epoch = try session.resetHistory()
    #expect(await resetIterator.next() != nil)
    #expect(await resetIterator.next() == nil)
    do {
        _ = try session.replay(since: beforeReset.checkpoint)
        Issue.record("Expected an old observation checkpoint to stay stale")
    } catch {
        #expect(error == .staleEpoch)
    }
    #expect(session.withLock { $0.observationCount } == 0)

    let beforeFinish = session.observeChanges()
    #expect(beforeFinish.checkpoint.epoch == epoch)
    var finishIterator = beforeFinish.notifications.makeAsyncIterator()
    let final = try session.finishIfQuiescent()
    #expect(final.isFinished)
    #expect(await finishIterator.next() != nil)
    #expect(await finishIterator.next() == nil)
    #expect(session.withLock { $0.observationCount } == 0)

    let closed = session.observeChanges()
    #expect(closed.initialSnapshot == final)
    var closedIterator = closed.notifications.makeAsyncIterator()
    #expect(await closedIterator.next() == nil)
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN033_explicitCancellationAndLeaseReleaseUnregister() async {
    let session = MockSession()
    let explicit = session.observeChanges()
    let stream = explicit.notifications
    #expect(session.withLock { $0.observationCount } == 1)
    explicit.cancel()
    explicit.cancel()
    #expect(session.withLock { $0.observationCount } == 0)
    var afterCancel = stream.makeAsyncIterator()
    #expect(await afterCancel.next() == nil)

    var abandoned: SessionObservation? = session.observeChanges()
    let detachedStream = abandoned!.notifications
    #expect(session.withLock { $0.observationCount } == 1)
    abandoned = nil
    #expect(session.withLock { $0.observationCount } == 0)
    var afterRelease = detachedStream.makeAsyncIterator()
    #expect(await afterRelease.next() == nil)
}

@Test func RUN033_cancellingAParkedIteratorUnregistersEvenWithTheLeaseRetained() async {
    let session = MockSession()
    let lease = session.observeChanges()
    let entered = AsyncStream<Void>.makeStream()
    let waiting = Task {
        var iterator = lease.notifications.makeAsyncIterator()
        entered.continuation.finish()
        return await iterator.next() != nil
    }
    for await _ in entered.stream {}
    waiting.cancel()
    #expect(await waiting.value == false)
    #expect(session.withLock { $0.observationCount } == 0)
    withExtendedLifetime(lease) {}
}

@Test func RUN033_pruningWakesTheReaderAndPreservesReplayGapErrors() async throws {
    let session = MockSession()
    let endpoint = observedEndpoint(session)
    let lease = session.observeChanges()
    defer { lease.cancel() }
    var pulses = lease.notifications.makeAsyncIterator()
    #expect(endpoint.invoke("before-prune") == "before-prune")
    #expect(await pulses.next() != nil)

    let cutoff = session.checkpoint()
    try session.discardEvents(through: cutoff)
    #expect(await pulses.next() != nil)
    do {
        _ = try session.replay(since: lease.checkpoint)
        Issue.record("A replay after eviction cannot prove the missing prefix")
    } catch {
        #expect(error == .historyUnavailable)
    }

    #expect(endpoint.invoke("after-prune") == "after-prune")
    #expect(await pulses.next() != nil)
    let retained = try session.replay(since: cutoff)
    #expect(retained.events.map(\.phase) == [.admitted, .returned])

    try session.discardEvents(through: cutoff)
    lease.cancel()
    #expect(await pulses.next() == nil)
}
