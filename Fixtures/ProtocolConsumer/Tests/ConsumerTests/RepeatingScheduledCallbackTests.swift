import BlueprintMocking
import Testing

private func scheduleRepeatingCallback(
    _ capture: EscapingCallbackCapture<Int, String>, input: Int, after delays: [Duration]
) throws(CallbackSchedulingError) -> ScheduledCallbackSeries<String> {
    try capture.scheduleRepeating(input, after: delays)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_repeatingScheduledCallbackPreservesSuppliedOrderAndExactDeadlines() throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<Int>(0)
    let fixture = try scheduledCallbackFixture(session: session) { input in
        #expect(session.snapshot().activeInvocationCount == 0)
        let count = calls.get() + 1
        calls.set(count)
        return "\(input)-\(count)"
    }
    let registered = session.snapshot()
    try session.advanceClock(by: .seconds(9))
    let series = try scheduleRepeatingCallback(fixture.capture, input: 17, after: [
        .seconds(4), .seconds(1), .seconds(3), .seconds(1)
    ])
    #expect(series.outcomes == [.pending, .pending, .pending, .pending])

    try session.advanceClock(by: .seconds(1) - .nanoseconds(1))
    #expect(series.outcomes == [.pending, .pending, .pending, .pending])
    #expect(calls.get() == 0)
    try session.advanceClock(by: .nanoseconds(1))
    #expect(series.outcomes == [.pending, .delivered("17-1"), .pending, .delivered("17-2")])

    try session.advanceClock(by: .seconds(3))
    let delivered: [ScheduledCallbackOutcome<String>] = [
        .delivered("17-4"), .delivered("17-1"), .delivered("17-3"), .delivered("17-2")
    ]
    #expect(series.outcomes == delivered)
    #expect(series.cancelPending() == 0)
    try session.advanceClock(by: .seconds(20))
    #expect(series.outcomes == delivered)
    #expect(calls.get() == 4)
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_repeatingScheduledCallbackCancellationKeepsAcquiredSiblings() throws {
    let session = MockSession(clock: .manual)
    let owner = StoredProperty<ScheduledCallbackSeries<String>?>(nil)
    defer { owner.set(nil) }
    let cancellations = StoredProperty<[Int]>([])
    let calls = StoredProperty<Int>(0)
    let fixture = try scheduledCallbackFixture(session: session) { input in
        let count = calls.get() + 1
        calls.set(count)
        if count == 1 {
            if let series = owner.get() {
                #expect(series.outcomes == [.pending, .pending, .pending, .pending])
                cancellations.set([series.cancelPending(), series.cancelPending()])
                #expect(series.outcomes == [.pending, .pending, .cancelled, .cancelled])
            } else {
                Issue.record("The series must be installed before advancing the manual clock")
            }
        }
        return "\(input)-\(count)"
    }
    let registered = session.snapshot()
    let series = try scheduleRepeatingCallback(fixture.capture, input: 23, after: [
        .seconds(2), .seconds(4), .seconds(6), .seconds(8)
    ])
    owner.set(series)
    let oneShot = try fixture.capture.schedule(31, after: .seconds(9))
    try session.advanceClock(by: .seconds(4))
    #expect(cancellations.get() == [2, 0])
    let completed: [ScheduledCallbackOutcome<String>] = [.delivered("23-1"), .delivered("23-2"), .cancelled, .cancelled]
    #expect(series.outcomes == completed)
    #expect(series.cancelPending() == 0)
    #expect(oneShot.outcome == .pending)
    try session.advanceClock(by: .seconds(10))
    #expect(series.outcomes == completed)
    #expect(oneShot.outcome == .delivered("31-3"))
    #expect(calls.get() == 3)
    #expect(session.snapshot() == registered)
    #expect(fixture.captor.captures.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_repeatingScheduledCallbackRejectsInvalidOffsetsAtomically() throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<Int>(0)
    let fixture = try scheduledCallbackFixture(session: session) { input in
        let count = calls.get() + 1
        calls.set(count)
        return "\(input)-\(count)"
    }
    #expect(throws: CallbackSchedulingError.negativeDelay) {
        try scheduleRepeatingCallback(fixture.capture, input: 29, after: [.zero, .seconds(1), .nanoseconds(-1)])
    }
    #expect(calls.get() == 0)
    try session.advanceClock(by: .seconds(5))
    #expect(calls.get() == 0)

    let empty = try scheduleRepeatingCallback(fixture.capture, input: 31, after: [])
    #expect(empty.outcomes.isEmpty)
    #expect(empty.cancelPending() == 0)

    let mixed = try scheduleRepeatingCallback(fixture.capture, input: 37, after: [.seconds(1), .zero, .zero])
    #expect(mixed.outcomes == [.pending, .delivered("37-1"), .delivered("37-2")])
    try session.advanceClock(by: .zero)
    #expect(calls.get() == 2)
    try session.advanceClock(by: .seconds(1))
    #expect(mixed.outcomes == [.delivered("37-3"), .delivered("37-1"), .delivered("37-2")])
    #expect(calls.get() == 3)
    #expect(fixture.captor.captures.count == 1)
}

private func verifyRepeatingScheduleRetirement(finishing: Bool) throws {
    let session = MockSession(clock: .manual)
    let calls = StoredProperty<Int>(0)
    let fixture = try scheduledCallbackFixture(session: session) { input in
        let count = calls.get() + 1
        calls.set(count)
        if count == 1 {
            do {
                if finishing {
                    _ = try session.finishIfQuiescent()
                } else {
                    _ = try session.resetHistory()
                }
            } catch {
                Issue.record("The first acquired replay could not retire its session: \(error)")
            }
        }
        return "\(input)-\(count)"
    }
    let registered = session.snapshot()
    let series = try scheduleRepeatingCallback(fixture.capture, input: 41, after: [.seconds(1), .seconds(1), .seconds(2)])
    try session.advanceClock(by: .seconds(1))

    let retired = session.snapshot()
    if finishing {
        #expect(retired.isFinished)
        #expect(retired.events == registered.events)
    } else {
        #expect(retired.epoch != registered.epoch)
        #expect(retired.events.isEmpty)
    }
    #expect(fixture.captor.captures.isEmpty)
    let expected: [ScheduledCallbackOutcome<String>] = [.delivered("41-1"), .delivered("41-2"), .unavailable]
    #expect(series.outcomes == expected)
    #expect(series.cancelPending() == 0)
    #expect(throws: CallbackSchedulingError.unavailable) {
        try scheduleRepeatingCallback(fixture.capture, input: 43, after: [.seconds(1)])
    }
    try session.advanceClock(by: .seconds(10))
    #expect(calls.get() == 2)
    #expect(series.outcomes == expected)
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_repeatingScheduledCallbackResetRetiresFutureOnly() throws {
    try verifyRepeatingScheduleRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_repeatingScheduledCallbackFinishRetiresFutureOnly() throws {
    try verifyRepeatingScheduleRetirement(finishing: true)
}
