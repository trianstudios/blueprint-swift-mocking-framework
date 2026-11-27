import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackCancellationRetiresExactQueuedReceipt() throws {
    let session = MockSession(clock: .manual)
    let received = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        received.set(received.get() + [input])
        return "delivered-\(input)"
    }
    let registered = session.snapshot()
    let cancelled = try fixture.capture.schedule(17, after: .seconds(3))
    let duplicate = try fixture.capture.schedule(17, after: .seconds(3))
    try session.advanceClock(by: .seconds(3) - .nanoseconds(1))

    #expect(cancelled.outcome == .pending)
    #expect(cancelled.cancel())
    #expect(cancelled.outcome == .cancelled)
    #expect(!cancelled.cancel())
    #expect(duplicate.outcome == .pending)
    #expect(received.get().isEmpty)
    #expect(session.snapshot() == registered)

    try session.advanceClock(by: .nanoseconds(1))
    #expect(cancelled.outcome == .cancelled)
    #expect(duplicate.outcome == .delivered("delivered-17"))
    #expect(!duplicate.cancel())
    try session.advanceClock(by: .seconds(5))
    #expect(received.get() == [17])
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackCancellationCannotChangeAnAcquiredDelivery() throws {
    let session = MockSession(clock: .manual)
    let otherReceipts = StoredProperty<(
        acquired: ScheduledCallbackDelivery<String>, queued: ScheduledCallbackDelivery<String>
    )?>(nil)
    defer { otherReceipts.set(nil) }
    let attempted = StoredProperty<Bool?>(nil)
    let received = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        received.set(received.get() + [input])
        if input == 1 {
            if let receipts = otherReceipts.get() {
                #expect(receipts.acquired.outcome == .pending)
                attempted.set(receipts.acquired.cancel())
                #expect(receipts.acquired.outcome == .pending)
                #expect(receipts.queued.cancel())
                #expect(receipts.queued.outcome == .cancelled)
            } else {
                Issue.record("The other receipts must be installed before advancing the clock")
            }
        }
        return "delivered-\(input)"
    }

    let first = try fixture.capture.schedule(1, after: .seconds(2))
    let second = try fixture.capture.schedule(2, after: .seconds(2))
    let later = try fixture.capture.schedule(3, after: .seconds(3))
    otherReceipts.set((acquired: second, queued: later))
    #expect(attempted.get() == nil)

    try session.advanceClock(by: .seconds(2))
    #expect(attempted.get() == false)
    #expect(first.outcome == .delivered("delivered-1"))
    #expect(second.outcome == .delivered("delivered-2"))
    #expect(!first.cancel())
    #expect(!second.cancel())
    #expect(later.outcome == .cancelled)
    #expect(!later.cancel())
    try session.advanceClock(by: .seconds(5))
    #expect(received.get() == [1, 2])
    #expect(fixture.captor.captures.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackCancellationRejectsFinishedReceipt() throws {
    let session = MockSession(clock: .manual)
    let received = StoredProperty<[Int]>([])
    let fixture = try scheduledCallbackFixture(session: session) { input in
        received.set(received.get() + [input])
        return String(input)
    }
    let delivery = try fixture.capture.schedule(23, after: .seconds(3))
    #expect(delivery.outcome == .pending)
    let closed = try session.finishIfQuiescent()

    #expect(delivery.outcome == .unavailable)
    #expect(!delivery.cancel())
    #expect(fixture.captor.captures.isEmpty)
    try session.advanceClock(by: .seconds(4))
    #expect(delivery.outcome == .unavailable)
    #expect(!delivery.cancel())
    #expect(received.get().isEmpty)
    #expect(session.snapshot() == closed)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackCancellationKeepsSessionsIndependent() throws {
    let left = MockSession(clock: .manual)
    let right = MockSession(clock: .manual)
    let received = StoredProperty<[String]>([])
    let leftFixture = try scheduledCallbackFixture(session: left) { input in
        received.set(received.get() + ["left-\(input)"])
        return "left-\(input)"
    }
    let rightFixture = try scheduledCallbackFixture(session: right) { input in
        received.set(received.get() + ["right-\(input)"])
        return "right-\(input)"
    }

    let leftDelivery = try leftFixture.capture.schedule(29, after: .seconds(2))
    let rightDelivery = try rightFixture.capture.schedule(29, after: .seconds(2))
    #expect(leftDelivery.cancel())
    #expect(!leftDelivery.cancel())
    #expect(rightDelivery.outcome == .pending)

    try left.advanceClock(by: .seconds(2))
    #expect(leftDelivery.outcome == .cancelled)
    #expect(rightDelivery.outcome == .pending)
    #expect(received.get().isEmpty)
    try right.advanceClock(by: .seconds(2))
    #expect(rightDelivery.outcome == .delivered("right-29"))
    #expect(!rightDelivery.cancel())
    #expect(received.get() == ["right-29"])
    #expect(leftFixture.captor.captures.count == 1)
    #expect(rightFixture.captor.captures.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_scheduledCallbackCancellationKeepsEpochsIndependent() throws {
    let session = MockSession(clock: .manual)
    let captor = EscapingCallbackCaptor<Int, String>(session: session)
    let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("scheduled"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    let received = StoredProperty<[String]>([])
    func register(_ label: String) throws -> EscapingCallbackCapture<Int, String> {
        #expect(registerEscapingCallback(mock, id: "scheduled") { input in
            let result = "\(label)-\(input)"
            received.set(received.get() + [result])
            return result
        } == "registered")
        return try #require(captor.captures.first)
    }

    let old = try register("old")
    let retiredReceipt = try old.schedule(31, after: .seconds(4))
    #expect(retiredReceipt.outcome == .pending)
    let epoch = try session.resetHistory()
    #expect(epoch != old.invocation.epoch)
    #expect(captor.captures.isEmpty)
    #expect(retiredReceipt.outcome == .unavailable)
    #expect(!retiredReceipt.cancel())

    let current = try register("current")
    #expect(current.invocation.epoch == epoch)
    let currentReceipt = try current.schedule(31, after: .seconds(4))
    #expect(!retiredReceipt.cancel())
    #expect(currentReceipt.outcome == .pending)
    try session.advanceClock(by: .seconds(4))
    #expect(currentReceipt.outcome == .delivered("current-31"))
    #expect(retiredReceipt.outcome == .unavailable)
    #expect(!retiredReceipt.cancel())
    #expect(received.get() == ["current-31"])
    #expect(captor.captures.count == 1)
}
