import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

func scheduledCallbackFixture(
    session: MockSession, using callback: @escaping @Sendable (Int) -> String
) throws -> (captor: EscapingCallbackCaptor<Int, String>, capture: EscapingCallbackCapture<Int, String>) {
    let captor = EscapingCallbackCaptor<Int, String>(session: session)
    let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("scheduled"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    #expect(registerEscapingCallback(mock, id: "scheduled", using: callback) == "registered")
    #expect(mock.verify.register(id: .equal("scheduled"), phase: .returned).wasCalled(.once).passed)
    try #require(captor.captures.count == 1)
    return (captor, try #require(captor.captures.first))
}

private func scheduleCallback(
    _ capture: EscapingCallbackCapture<Int, String>, input: Int, delay: Duration
) throws(CallbackSchedulingError) -> ScheduledCallbackDelivery<String> {
    try capture.schedule(input, after: delay)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackDeliversAtExactManualDeadlineOnce() throws {
    let session = MockSession(clock: .manual)
    let received = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        #expect(session.snapshot().events.last?.phase == .returned)
        received.set(received.get() + [input])
        return "delivered-\(input)"
    }
    let registered = session.snapshot()
    #expect(registered.events.map(\.phase) == [.admitted, .returned])
    #expect(registered.events.first == fixture.capture.invocation)
    #expect(received.get().isEmpty)

    try session.advanceClock(by: .seconds(9))
    let delivery = try scheduleCallback(fixture.capture, input: 17, delay: .seconds(1))
    #expect(delivery.outcome == .pending)
    try session.advanceClock(by: .seconds(1) - .nanoseconds(1))
    #expect(delivery.outcome == .pending)
    #expect(received.get().isEmpty)
    #expect(session.snapshot() == registered)

    try session.advanceClock(by: .nanoseconds(1))
    #expect(delivery.outcome == .delivered("delivered-17"))
    #expect(received.get() == [17])
    try session.advanceClock(by: .seconds(5))
    #expect(delivery.outcome == .delivered("delivered-17"))
    #expect(received.get() == [17])

    let immediate = try scheduleCallback(fixture.capture, input: 23, delay: .zero)
    #expect(immediate.outcome == .delivered("delivered-23"))
    #expect(received.get() == [17, 23])
    try session.advanceClock(by: .zero)
    #expect(received.get() == [17, 23])
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

private func verifyScheduledCallbackRetirement(finishing: Bool) throws {
    let session = MockSession(clock: .manual)
    let received = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        received.set(received.get() + [input])
        return "unexpected-\(input)"
    }
    let registered = session.snapshot()
    let delivery = try scheduleCallback(fixture.capture, input: 31, delay: .seconds(5))
    try session.advanceClock(by: .seconds(4))
    #expect(delivery.outcome == .pending)
    #expect(received.get().isEmpty)
    #expect(session.snapshot() == registered)

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
    #expect(delivery.outcome == .unavailable)
    #expect(received.get().isEmpty)
    #expect(fixture.captor.captures.isEmpty)
    #expect(throws: CallbackSchedulingError.unavailable) {
        try scheduleCallback(fixture.capture, input: 37, delay: .seconds(1))
    }

    try session.advanceClock(by: .seconds(5))
    #expect(delivery.outcome == .unavailable)
    #expect(received.get().isEmpty)
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackResetRetiresPendingDelivery() throws {
    try verifyScheduledCallbackRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackFinishRetiresPendingDelivery() throws {
    try verifyScheduledCallbackRetirement(finishing: true)
}

@Test func GEN016_scheduledCallbackRejectsInvalidClockAndDelay() throws {
    let received = StoredProperty<[Int]>([])
    let callback: @Sendable (Int) -> String = { input in
        received.set(received.get() + [input])
        return String(input)
    }

    let manual = MockSession(clock: .manual)
    let manualFixture = try scheduledCallbackFixture(session: manual, using: callback)
    #expect(throws: CallbackSchedulingError.negativeDelay) {
        try scheduleCallback(manualFixture.capture, input: 41, delay: .nanoseconds(-1))
    }
    try manual.advanceClock(by: .seconds(1))
    #expect(manualFixture.captor.captures.count == 1)

    let continuous = MockSession()
    let continuousFixture = try scheduledCallbackFixture(session: continuous, using: callback)
    #expect(throws: CallbackSchedulingError.requiresManualClock) {
        try continuousFixture.capture.scheduleRepeating(43, after: [.seconds(1)])
    }
    #expect(continuousFixture.captor.captures.count == 1)
    #expect(received.get().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbacksAcquiredTogetherFinishAfterReentrantReset() throws {
    let session = MockSession(clock: .manual)
    let originalEpoch = session.snapshot().epoch
    let received = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        received.set(received.get() + [input])
        if input == 1 {
            do {
                _ = try session.resetHistory()
            } catch {
                Issue.record("The first acquired delivery could not reset its session: \(error)")
            }
        } else if input == 2 {
            #expect(session.snapshot().epoch != originalEpoch)
        }
        return "delivered-\(input)"
    }

    let first = try scheduleCallback(fixture.capture, input: 1, delay: .seconds(5))
    let second = try scheduleCallback(fixture.capture, input: 2, delay: .seconds(5))
    let later = try scheduleCallback(fixture.capture, input: 3, delay: .seconds(6))
    #expect(received.get().isEmpty)
    try session.advanceClock(by: .seconds(5))

    #expect(first.outcome == .delivered("delivered-1"))
    #expect(second.outcome == .delivered("delivered-2"))
    #expect(later.outcome == .unavailable)
    #expect(received.get() == [1, 2])
    #expect(session.snapshot().events.isEmpty)
    #expect(fixture.captor.captures.isEmpty)
    try session.advanceClock(by: .seconds(5))
    #expect(received.get() == [1, 2])
    #expect(later.outcome == .unavailable)
}
