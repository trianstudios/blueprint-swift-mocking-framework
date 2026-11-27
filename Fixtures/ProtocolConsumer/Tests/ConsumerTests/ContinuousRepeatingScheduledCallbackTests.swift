import BlueprintMocking
import Dispatch
import Testing

private func waitForContinuousSeries(
    _ series: ScheduledCallbackSeries<String>
) async throws -> [ScheduledCallbackOutcome<String>] {
    var outcomes = series.outcomes
    while outcomes.contains(.pending) {
        try Task.checkCancellation()
        await Task.yield()
        outcomes = series.outcomes
    }
    return outcomes
}

private struct ContinuousSeriesReceiptGate: Sendable {
    private let installed = DispatchSemaphore(value: 0)
    private let stored = StoredProperty<ScheduledCallbackSeries<String>?>(nil)

    func publish(_ series: ScheduledCallbackSeries<String>) {
        stored.set(series)
        installed.signal()
    }

    func waitForReceipt() -> ScheduledCallbackSeries<String>? {
        guard installed.wait(timeout: .now() + .seconds(30)) == .success else { return nil }
        return stored.get()
    }

    func release() {
        stored.set(nil)
        installed.signal()
    }
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousRepeatingScheduledCallbackUsesDeadlineAndSuppliedTieOrder() async throws {
    let session = MockSession()
    let zeroCalls = StoredProperty<Int>(0)
    let timedCalls = StoredProperty<Int>(0)
    let signal = AsyncStream<ContinuousClock.Instant>.makeStream()
    defer { signal.continuation.finish() }
    let fixture = try scheduledCallbackFixture(session: session) { input in
        let firedAt = ContinuousClock.now
        if input == 0 {
            let count = zeroCalls.get() + 1
            zeroCalls.set(count)
            return "zero-\(count)"
        }
        let count = timedCalls.get() + 1
        timedCalls.set(count)
        signal.continuation.yield(firedAt)
        return "timed-\(count)"
    }
    let registered = session.snapshot()

    let empty = try fixture.capture.scheduleRepeating(0, after: [])
    #expect(empty.outcomes.isEmpty)
    #expect(empty.cancelPending() == 0)
    #expect(zeroCalls.get() == 0)
    let zero = try fixture.capture.scheduleRepeating(0, after: [.zero, .zero])
    #expect(zero.outcomes == [.delivered("zero-1"), .delivered("zero-2")])
    #expect(zeroCalls.get() == 2)
    #expect(zero.cancelPending() == 0)

    let delays: [Duration] = [.milliseconds(90), .milliseconds(30), .milliseconds(60), .milliseconds(30)]
    let beforeScheduling = ContinuousClock.now
    let series = try fixture.capture.scheduleRepeating(17, after: delays)
    var arrivals = signal.stream.makeAsyncIterator()
    for index in [1, 3, 2, 0] {
        let observed = await arrivals.next()
        let actual = try #require(observed)
        #expect(beforeScheduling.duration(to: actual) >= delays[index])
    }

    let outcomes = try await waitForContinuousSeries(series)
    #expect(outcomes == [.delivered("timed-4"), .delivered("timed-1"), .delivered("timed-3"), .delivered("timed-2")])
    #expect(timedCalls.get() == 4)
    #expect(series.cancelPending() == 0)
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousRepeatingScheduledCallbackCancelsQueuedTiesFromFirstReplay() async throws {
    let session = MockSession()
    let gate = ContinuousSeriesReceiptGate()
    defer { gate.release() }
    let signal = AsyncStream<Void>.makeStream()
    defer { signal.continuation.finish() }
    let calls = StoredProperty<Int>(0)
    let cancellation = StoredProperty<(
        before: [ScheduledCallbackOutcome<String>], removed: [Int], after: [ScheduledCallbackOutcome<String>]
    )?>(nil)

    let fixture = try scheduledCallbackFixture(session: session) { input in
        let count = calls.get() + 1
        calls.set(count)
        if count == 1 {
            if let series = gate.waitForReceipt() {
                let before = series.outcomes
                let removed = [series.cancelPending(), series.cancelPending()]
                cancellation.set((before, removed, series.outcomes))
            }
            signal.continuation.finish()
        }
        return "\(input)-\(count)"
    }
    let registered = session.snapshot()
    let delay = Duration.milliseconds(30)
    let series = try fixture.capture.scheduleRepeating(23, after: [delay, delay, delay, .seconds(3600)])
    gate.publish(series)

    for await _ in signal.stream {}
    let observed = try #require(cancellation.get())
    #expect(observed.before == [.pending, .pending, .pending, .pending])
    #expect(observed.removed == [3, 0])
    #expect(observed.after == [.pending, .cancelled, .cancelled, .cancelled])
    let completed = try await waitForContinuousSeries(series)
    #expect(completed == [.delivered("23-1"), .cancelled, .cancelled, .cancelled])
    #expect(calls.get() == 1)
    #expect(series.cancelPending() == 0)
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

private func verifyContinuousRepeatingRetirement(finishing: Bool) async throws {
    let session = MockSession()
    let gate = ContinuousSeriesReceiptGate()
    defer { gate.release() }
    let signal = AsyncStream<Void>.makeStream()
    defer { signal.continuation.finish() }
    let calls = StoredProperty<Int>(0)
    let retirement = StoredProperty<(
        before: [ScheduledCallbackOutcome<String>], after: [ScheduledCallbackOutcome<String>]
    )?>(nil)
    let failure = StoredProperty<String?>(nil)
    let fixture = try scheduledCallbackFixture(session: session) { input in
        let count = calls.get() + 1
        calls.set(count)
        if count == 1 {
            if let series = gate.waitForReceipt() {
                let before = series.outcomes
                do {
                    if finishing {
                        _ = try session.finishIfQuiescent()
                    } else {
                        _ = try session.resetHistory()
                    }
                } catch {
                    failure.set(String(describing: error))
                }
                retirement.set((before, series.outcomes))
            }
            signal.continuation.finish()
        }
        return "\(input)-\(count)"
    }

    let registered = session.snapshot()
    let delay = Duration.milliseconds(30)
    let series = try fixture.capture.scheduleRepeating(29, after: [delay, delay, delay])
    gate.publish(series)

    for await _ in signal.stream {}
    let observed = try #require(retirement.get())
    #expect(failure.get() == nil)
    #expect(observed.before == [.pending, .pending, .pending])
    #expect(observed.after == [.pending, .unavailable, .unavailable])
    let completed = try await waitForContinuousSeries(series)
    #expect(completed == [.delivered("29-1"), .unavailable, .unavailable])
    #expect(calls.get() == 1)
    #expect(series.cancelPending() == 0)
    #expect(fixture.captor.captures.isEmpty)
    let retired = session.snapshot()
    #expect(retired.activeInvocationCount == 0)
    if finishing {
        #expect(retired.isFinished)
        #expect(retired.events == registered.events)
    } else {
        #expect(retired.epoch != registered.epoch)
        #expect(retired.events.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousRepeatingScheduledCallbackResetRetiresQueuedTies() async throws {
    try await verifyContinuousRepeatingRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousRepeatingScheduledCallbackFinishRetiresQueuedTies() async throws {
    try await verifyContinuousRepeatingRetirement(finishing: true)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousRepeatingScheduledCallbackDeallocationRetiresEveryReceipt() throws {
    let calls = StoredProperty<Int>(0)
    weak var retainedSession: MockSession?

    func makeSeries() throws -> ScheduledCallbackSeries<String> {
        let session = MockSession()
        retainedSession = session
        let fixture = try scheduledCallbackFixture(session: session) { input in
            calls.set(calls.get() + 1)
            return String(input)
        }
        let series = try fixture.capture.scheduleRepeating(31, after: [.seconds(3600), .seconds(3600), .seconds(7200)])
        #expect(series.outcomes == [.pending, .pending, .pending])
        #expect(fixture.captor.captures.count == 1)
        return series
    }

    let series = try makeSeries()
    #expect(retainedSession == nil)
    #expect(series.outcomes == [.unavailable, .unavailable, .unavailable])
    #expect(series.cancelPending() == 0)
    #expect(calls.get() == 0)
}
