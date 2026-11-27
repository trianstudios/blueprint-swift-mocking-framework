import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

private func continuousOneShotFixture(
    session: MockSession, using callback: @escaping @Sendable (Int) -> String
) throws -> (
    captor: OneShotEscapingCallbackCaptor<Int, String>,
    capture: OneShotEscapingCallbackCapture<Int, String>
) {
    let captor = OneShotEscapingCallbackCaptor<Int, String>(session: session)
    let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("continuous")).capturingCallbackOnce(into: captor).willReturn("registered")
    }
    let registered = registerEscapingCallback(mock, id: "continuous", using: callback)
    #expect(registered == "registered")
    #expect(mock.verify.register(id: .equal("continuous"), phase: .returned).wasCalled(.once).passed)
    try #require(captor.captures.count == 1)
    return (captor, try #require(captor.captures.first))
}

@Test func RUN010_continuousOneShotZeroDelayAndDirectInvocationShareOneClaim() throws {
    let session = MockSession()
    let calls = StoredProperty<[Int]>([])
    let record: @Sendable (Int) -> String = { input in
        calls.set(calls.get() + [input])
        return "delivered-\(input)"
    }
    let scheduled = try continuousOneShotFixture(session: session, using: record)
    let direct = try continuousOneShotFixture(session: session, using: record)
    defer { withExtendedLifetime((scheduled.captor, direct.captor)) {} }

    let receipt = try scheduled.capture.schedule(11, after: .zero)
    #expect(receipt.outcome == .delivered("delivered-11"))
    #expect(!receipt.cancel())
    #expect(calls.get() == [11])
    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try scheduled.capture.invoke(13) }

    #expect(try direct.capture.invoke(17) == "delivered-17")
    #expect(throws: OneShotCallbackSchedulingError.delivery(.alreadyAcquired)) {
        try direct.capture.schedule(19, after: .zero)
    }
    #expect(calls.get() == [11, 17])
}

@Test(.timeLimit(.minutes(1)))
func RUN010_continuousOneShotTimerHonorsDeadlineAndFinishesAcquiredDelivery() async throws {
    let session = MockSession()
    let entered = AsyncStream<ContinuousClock.Instant>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer {
        entered.continuation.finish()
        release.signal()
    }
    let calls = StoredProperty<[Int]>([])
    let fixture = try continuousOneShotFixture(session: session) { input in
        let startedAt = ContinuousClock.now
        calls.set(calls.get() + [input])
        if input == 23 {
            entered.continuation.yield(startedAt)
            guard release.wait(timeout: .now() + .seconds(30)) == .success else {
                return "test gate timed out"
            }
        }
        return "delivered-\(input)"
    }
    defer { withExtendedLifetime(fixture.captor) {} }

    let registered = session.snapshot()
    let delay = Duration.milliseconds(30)
    let beforeRegistration = ContinuousClock.now
    let receipt = try fixture.capture.schedule(23, after: delay)
    var arrivals = entered.stream.makeAsyncIterator()
    let observed = await arrivals.next()
    let enteredAt = try #require(observed)
    #expect(beforeRegistration.duration(to: enteredAt) >= delay)
    #expect(receipt.outcome == .pending)
    #expect(!receipt.cancel())
    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try fixture.capture.invoke(29) }
    #expect(calls.get() == [23])

    let finished = try session.finishIfQuiescent()
    #expect(finished.isFinished)
    #expect(finished.events == registered.events)
    #expect(finished.activeInvocationCount == 0)
    #expect(fixture.captor.captures.isEmpty)
    #expect(receipt.outcome == .pending)
    #expect(throws: OneShotCallbackDeliveryError.finished) { try fixture.capture.invoke(31) }

    release.signal()
    while receipt.outcome == .pending {
        try Task.checkCancellation()
        await Task.yield()
    }
    #expect(receipt.outcome == .delivered("delivered-23"))
    #expect(!receipt.cancel())
    #expect(calls.get() == [23])
    #expect(session.snapshot() == finished)
}

@Test func RUN010_continuousOneShotPendingAttemptsRespectCancelDirectWinAndTeardown() throws {
    let session = MockSession()
    let calls = StoredProperty<[Int]>([])
    let record: @Sendable (Int) -> String = { input in
        calls.set(calls.get() + [input])
        return "delivered-\(input)"
    }
    let delay = Duration.seconds(3600)
    let cancelled = try continuousOneShotFixture(session: session, using: record)
    let direct = try continuousOneShotFixture(session: session, using: record)
    let reset = try continuousOneShotFixture(session: session, using: record)
    defer { withExtendedLifetime((cancelled.captor, direct.captor, reset.captor)) {} }

    let cancelledAttempt = try cancelled.capture.schedule(37, after: delay)
    let directContender = try direct.capture.schedule(41, after: delay)
    let resetAttempt = try reset.capture.schedule(43, after: delay)
    #expect(cancelledAttempt.outcome == .pending)
    #expect(directContender.outcome == .pending)
    #expect(resetAttempt.outcome == .pending)
    #expect(calls.get().isEmpty)

    #expect(cancelledAttempt.cancel())
    #expect(cancelledAttempt.outcome == .cancelled)
    #expect(!cancelledAttempt.cancel())
    #expect(try cancelled.capture.invoke(47) == "delivered-47")
    #expect(try direct.capture.invoke(53) == "delivered-53")
    #expect(directContender.outcome == .pending)
    #expect(throws: OneShotCallbackSchedulingError.delivery(.alreadyAcquired)) {
        try direct.capture.schedule(59, after: delay)
    }

    let epoch = try session.resetHistory()
    #expect(epoch != reset.capture.invocation.epoch)
    #expect(resetAttempt.outcome == .rejected(.unavailable))
    #expect(directContender.outcome == .rejected(.unavailable))
    #expect(cancelledAttempt.outcome == .cancelled)
    #expect(!resetAttempt.cancel())
    #expect(throws: OneShotCallbackSchedulingError.delivery(.unavailable)) {
        try reset.capture.schedule(61, after: delay)
    }

    let fresh = try continuousOneShotFixture(session: session, using: record)
    defer { withExtendedLifetime(fresh.captor) {} }
    let finishAttempt = try fresh.capture.schedule(67, after: delay)
    #expect(finishAttempt.outcome == .pending)
    let finished = try session.finishIfQuiescent()
    #expect(finishAttempt.outcome == .rejected(.finished))
    #expect(!finishAttempt.cancel())
    #expect(throws: OneShotCallbackSchedulingError.delivery(.finished)) {
        try fresh.capture.schedule(71, after: .zero)
    }
    #expect(calls.get() == [47, 53])
    #expect(session.snapshot() == finished)
}
