import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

private func scheduledOneShotFixture(
    session: MockSession, calls: StoredProperty<[Int]>,
    onDelivery: @escaping @Sendable (Int) -> Void = { _ in }
) throws -> (
    captor: OneShotEscapingCallbackCaptor<Int, String>,
    capture: OneShotEscapingCallbackCapture<Int, String>
) {
    let captor = OneShotEscapingCallbackCaptor<Int, String>(session: session)
    let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("scheduled")).capturingCallbackOnce(into: captor).willReturn("registered")
    }
    let registered = registerEscapingCallback(mock, id: "scheduled") { input in
        calls.set(calls.get() + [input])
        onDelivery(input)
        return "delivered-\(input)"
    }
    #expect(registered == "registered")
    #expect(mock.verify.register(id: .equal("scheduled"), phase: .returned).wasCalled(.once).passed)
    try #require(captor.captures.count == 1)
    return (captor, try #require(captor.captures.first))
}

@Test func RUN010_scheduledOneShotCompetesWithDirectDeliveryAtDeadline() throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<[Int]>([])
    let direct = try scheduledOneShotFixture(session: session, calls: calls)
    let timed = try scheduledOneShotFixture(session: session, calls: calls)
    defer { withExtendedLifetime((direct.captor, timed.captor)) {} }

    let directContender = try direct.capture.schedule(17, after: .seconds(1))
    let timedWinner = try timed.capture.schedule(23, after: .seconds(1))
    try session.advanceClock(by: .seconds(1) - .nanoseconds(1))
    #expect(directContender.outcome == .pending)
    #expect(timedWinner.outcome == .pending)
    #expect(calls.get().isEmpty)

    #expect(try direct.capture.invoke(11) == "delivered-11")
    #expect(directContender.outcome == .pending)
    #expect(calls.get() == [11])

    try session.advanceClock(by: .nanoseconds(1))
    #expect(directContender.outcome == .rejected(.alreadyAcquired))
    #expect(timedWinner.outcome == .delivered("delivered-23"))
    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try timed.capture.invoke(29) }
    #expect(!directContender.cancel())
    #expect(!timedWinner.cancel())
    try session.advanceClock(by: .seconds(9))
    #expect(calls.get() == [11, 23])
}

@Test(.timeLimit(.minutes(1)))
func RUN010_scheduledOneShotKeepsAcquiredCallbackThroughFinish() async throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<[Int]>([])
    let entered = AsyncStream<Bool>.makeStream()
    let completed = AsyncStream<Bool>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let releasedInTime = StoredProperty(false)
    defer { release.signal() }

    let fixture = try scheduledOneShotFixture(session: session, calls: calls) { input in
        if input == 103 {
            entered.continuation.yield(true)
            releasedInTime.set(release.wait(timeout: .now() + .seconds(30)) == .success)
        }
    }
    defer { withExtendedLifetime(fixture.captor) {} }
    let receipt = try fixture.capture.schedule(103, after: .seconds(1))
    DispatchQueue.global().async {
        defer {
            entered.continuation.finish()
            completed.continuation.finish()
        }
        do {
            try session.advanceClock(by: .seconds(1))
            completed.continuation.yield(true)
        } catch {
            completed.continuation.yield(false)
        }
    }

    var arrivals = entered.stream.makeAsyncIterator()
    let started = await arrivals.next()
    try #require(started == true)
    #expect(receipt.outcome == .pending)
    #expect(!receipt.cancel())
    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try fixture.capture.invoke(107) }
    #expect(calls.get() == [103])

    let finished = try session.finishIfQuiescent()
    #expect(receipt.outcome == .pending)
    #expect(throws: OneShotCallbackDeliveryError.finished) { try fixture.capture.invoke(109) }
    release.signal()

    var outcomes = completed.stream.makeAsyncIterator()
    let advanced = await outcomes.next()
    #expect(advanced == true)
    #expect(releasedInTime.get())
    #expect(receipt.outcome == .delivered("delivered-103"))
    #expect(session.snapshot() == finished)
    #expect(calls.get() == [103])
}

@Test func RUN010_scheduledOneShotAcquiresEarliestOfTwoDueContenders() throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<[Int]>([])
    let fixture = try scheduledOneShotFixture(session: session, calls: calls)
    let immediate = try scheduledOneShotFixture(session: session, calls: calls)
    defer { withExtendedLifetime((fixture.captor, immediate.captor)) {} }

    let later = try fixture.capture.schedule(37, after: .seconds(5))
    let earlier = try fixture.capture.schedule(31, after: .seconds(2))
    #expect(later.outcome == .pending)
    #expect(earlier.outcome == .pending)
    #expect(calls.get().isEmpty)

    let inline = try immediate.capture.schedule(41, after: .zero)
    #expect(inline.outcome == .delivered("delivered-41"))
    #expect(calls.get() == [41])
    #expect(!inline.cancel())

    try session.advanceClock(by: .seconds(5))
    #expect(earlier.outcome == .delivered("delivered-31"))
    #expect(later.outcome == .rejected(.alreadyAcquired))
    #expect(calls.get() == [41, 31])
}

@Test func RUN010_cancellingScheduledOneShotAttemptLeavesCaptureAvailable() throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<[Int]>([])
    let attempt = try scheduledOneShotFixture(session: session, calls: calls)
    let capture = try scheduledOneShotFixture(session: session, calls: calls)
    defer { withExtendedLifetime((attempt.captor, capture.captor)) {} }

    let cancelledAttempt = try attempt.capture.schedule(43, after: .seconds(4))
    let queuedForCancelledCapture = try capture.capture.schedule(47, after: .seconds(4))
    #expect(cancelledAttempt.cancel())
    #expect(cancelledAttempt.outcome == .cancelled)
    #expect(!cancelledAttempt.cancel())
    #expect(calls.get().isEmpty)
    #expect(try attempt.capture.invoke(53) == "delivered-53")

    try capture.capture.cancel()
    #expect(queuedForCancelledCapture.outcome == .pending)
    #expect(throws: OneShotCallbackSchedulingError.delivery(.cancelled)) {
        try capture.capture.schedule(59, after: .seconds(1))
    }
    try session.advanceClock(by: .seconds(4))
    #expect(cancelledAttempt.outcome == .cancelled)
    #expect(queuedForCancelledCapture.outcome == .rejected(.cancelled))
    #expect(!queuedForCancelledCapture.cancel())
    #expect(calls.get() == [53])
}

@Test func RUN010_scheduledOneShotResetAndFinishRejectQueuedDeliveries() throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<[Int]>([])
    let old = try scheduledOneShotFixture(session: session, calls: calls)
    defer { withExtendedLifetime(old.captor) {} }
    let resetDelivery = try old.capture.schedule(61, after: .seconds(7))
    #expect(resetDelivery.outcome == .pending)
    let resetEpoch = try session.resetHistory()
    #expect(resetEpoch != old.capture.invocation.epoch)
    #expect(resetDelivery.outcome == .rejected(.unavailable))
    #expect(old.captor.captures.isEmpty)
    #expect(!resetDelivery.cancel())
    #expect(throws: OneShotCallbackSchedulingError.delivery(.unavailable)) {
        try old.capture.schedule(61, after: .seconds(7))
    }

    let fresh = try scheduledOneShotFixture(session: session, calls: calls)
    defer { withExtendedLifetime(fresh.captor) {} }
    let finishedDelivery = try fresh.capture.schedule(67, after: .seconds(7))
    #expect(finishedDelivery.outcome == .pending)
    let finished = try session.finishIfQuiescent()
    #expect(finished.isFinished)
    #expect(finishedDelivery.outcome == .rejected(.finished))
    #expect(fresh.captor.captures.isEmpty)
    #expect(!finishedDelivery.cancel())
    #expect(throws: OneShotCallbackSchedulingError.delivery(.finished)) {
        try fresh.capture.schedule(71, after: .seconds(1))
    }
    #expect(throws: OneShotCallbackSchedulingError.delivery(.unavailable)) {
        try old.capture.schedule(73, after: .zero)
    }

    try session.advanceClock(by: .seconds(8))
    #expect(resetDelivery.outcome == .rejected(.unavailable))
    #expect(finishedDelivery.outcome == .rejected(.finished))
    #expect(calls.get().isEmpty)
    #expect(session.snapshot() == finished)
}

@Test func RUN010_scheduledOneShotRejectsInvalidAndContinuousSchedulingWithoutClaiming() throws {
    let manual = MockSession(clock: .manual)
    let continuous = MockSession()
    let calls = StoredProperty<[Int]>([])
    let manualFixture = try scheduledOneShotFixture(session: manual, calls: calls)
    let continuousFixture = try scheduledOneShotFixture(session: continuous, calls: calls)
    defer { withExtendedLifetime((manualFixture.captor, continuousFixture.captor)) {} }

    #expect(throws: OneShotCallbackSchedulingError.negativeDelay) {
        try manualFixture.capture.schedule(79, after: .nanoseconds(-1))
    }
    for delay in [Duration.zero, .seconds(30)] {
        #expect(throws: OneShotCallbackSchedulingError.requiresManualClock) {
            try continuousFixture.capture.schedule(83, after: delay)
        }
    }
    #expect(calls.get().isEmpty)
    #expect(try manualFixture.capture.invoke(89) == "delivered-89")
    #expect(try continuousFixture.capture.invoke(97) == "delivered-97")
    try manual.advanceClock(by: .seconds(1))
    #expect(calls.get() == [89, 97])
}

@Test func RUN010_droppingManualSessionRejectsPendingScheduledOneShot() throws {
    let calls = StoredProperty<[Int]>([])
    weak var owner: MockSession?
    func scheduleAndDropSession() throws -> ScheduledOneShotCallbackDelivery<String> {
        let session = MockSession(clock: .manual)
        owner = session
        let fixture = try scheduledOneShotFixture(session: session, calls: calls)
        defer { withExtendedLifetime(fixture.captor) {} }
        return try fixture.capture.schedule(101, after: .seconds(8))
    }

    let receipt = try scheduleAndDropSession()
    #expect(owner == nil)
    #expect(receipt.outcome == .rejected(.unavailable))
    #expect(!receipt.cancel())
    #expect(calls.get().isEmpty)
}
