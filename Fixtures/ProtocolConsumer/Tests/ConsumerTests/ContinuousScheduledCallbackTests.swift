import BlueprintMocking
import Dispatch
import Testing

private func waitForContinuousCallbackOutcome(
    _ receipt: ScheduledCallbackDelivery<String>
) async throws -> ScheduledCallbackOutcome<String> {
    var outcome = receipt.outcome
    while outcome == .pending {
        try Task.checkCancellation()
        await Task.yield()
        outcome = receipt.outcome
    }
    return outcome
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousScheduledCallbackRespectsMonotonicDeadlineAcrossFinish() async throws {
    let session = MockSession()
    let calls = StoredProperty<[Int]>([])
    let finished = StoredProperty<Result<SessionSnapshot, SessionFinishError>?>(nil)
    let signal = AsyncStream<ContinuousClock.Instant>.makeStream()
    defer { signal.continuation.finish() }
    let installed = DispatchSemaphore(value: 0)
    let installedReceipt = StoredProperty<ScheduledCallbackDelivery<String>?>(nil)
    defer { installedReceipt.set(nil) }
    let fixture = try scheduledCallbackFixture(session: session) { input in
        let observedAt = ContinuousClock.now
        calls.set(calls.get() + [input])
        if input == 17 {
            // Let the test publish the receipt even if the timer starts on another thread.
            if installed.wait(timeout: .now() + .seconds(30)) == .timedOut {
                Issue.record("The one-shot receipt was not installed")
            }
            let acquired = installedReceipt.get()
            #expect(acquired?.outcome == .pending)
            #expect(acquired?.cancel() == false)
            do throws(SessionFinishError) {
                finished.set(.success(try session.finishIfQuiescent()))
            } catch {
                finished.set(.failure(error))
            }
            #expect(acquired?.outcome == .pending)
            signal.continuation.yield(observedAt)
            signal.continuation.finish()
        }
        return "delivered-\(input)"
    }
    let registered = session.snapshot()
    #expect(registered.events.map(\.phase) == [.admitted, .returned])
    #expect(registered.activeInvocationCount == 0)
    #expect(calls.get().isEmpty)

    let immediate = try fixture.capture.schedule(0, after: .zero)
    #expect(immediate.outcome == .delivered("delivered-0"))
    #expect(!immediate.cancel())
    #expect(calls.get() == [0])

    let delay = Duration.milliseconds(30)
    let beforeScheduling = ContinuousClock.now
    let receipt = try fixture.capture.schedule(17, after: delay)
    installedReceipt.set(receipt)
    installed.signal()
    var deliveryTimes = signal.stream.makeAsyncIterator()
    let observed = await deliveryTimes.next()
    let firedAt = try #require(observed)
    #expect(beforeScheduling.duration(to: firedAt) >= delay)
    #expect(try await waitForContinuousCallbackOutcome(receipt) == .delivered("delivered-17"))
    let result = try #require(finished.get())
    let closed = try result.get()
    #expect(closed.isFinished)
    #expect(closed.events == registered.events)
    #expect(closed.activeInvocationCount == 0)
    #expect(session.snapshot() == closed)
    #expect(fixture.captor.captures.isEmpty)
    #expect(!receipt.cancel())
    #expect(calls.get() == [0, 17])
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousScheduledCallbackCancellationStaysRetired() throws {
    let session = MockSession()
    let calls = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        calls.set(calls.get() + [input])
        return String(input)
    }
    let registered = session.snapshot()
    let receipt = try fixture.capture.schedule(23, after: .seconds(3600))
    #expect(receipt.outcome == .pending)
    #expect(receipt.cancel())
    #expect(receipt.outcome == .cancelled)
    #expect(!receipt.cancel())
    #expect(throws: CallbackSchedulingError.negativeDelay) {
        try fixture.capture.scheduleRepeating(29, after: [.zero, .nanoseconds(-1)])
    }
    #expect(receipt.outcome == .cancelled)
    #expect(calls.get().isEmpty)
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

private func verifyContinuousScheduleRetirement(finishing: Bool) throws {
    let session = MockSession()
    let calls = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        calls.set(calls.get() + [input])
        return String(input)
    }
    let registered = session.snapshot()
    let receipt = try fixture.capture.schedule(31, after: .seconds(3600))
    #expect(receipt.outcome == .pending)
    if finishing {
        let closed = try session.finishIfQuiescent()
        #expect(closed.isFinished)
        #expect(closed.events == registered.events)
    } else {
        let epoch = try session.resetHistory()
        #expect(epoch != registered.epoch)
        #expect(session.snapshot().events.isEmpty)
    }
    let retired = session.snapshot()
    #expect(receipt.outcome == .unavailable)
    #expect(!receipt.cancel())
    #expect(throws: CallbackSchedulingError.unavailable) {
        try fixture.capture.schedule(37, after: .seconds(3600))
    }
    #expect(receipt.outcome == .unavailable)
    #expect(!receipt.cancel())
    #expect(fixture.captor.captures.isEmpty)
    #expect(calls.get().isEmpty)
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousScheduledCallbackResetRetiresFarFutureDelivery() throws {
    try verifyContinuousScheduleRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousScheduledCallbackFinishRetiresFarFutureDelivery() throws {
    try verifyContinuousScheduleRetirement(finishing: true)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_continuousScheduledCallbackDoesNotKeepSessionAlive() throws {
    let calls = StoredProperty<[Int]>([])
    weak var retainedSession: MockSession?

    func makeReceipt() throws -> ScheduledCallbackDelivery<String> {
        let session = MockSession()
        retainedSession = session
        let fixture = try scheduledCallbackFixture(session: session) { input in
            calls.set(calls.get() + [input])
            return String(input)
        }
        let receipt = try fixture.capture.schedule(41, after: .seconds(3600))
        #expect(receipt.outcome == .pending)
        #expect(fixture.captor.captures.count == 1)
        return receipt
    }

    let receipt = try makeReceipt()
    #expect(retainedSession == nil)
    #expect(receipt.outcome == .unavailable)
    #expect(!receipt.cancel())
    #expect(calls.get().isEmpty)
}
