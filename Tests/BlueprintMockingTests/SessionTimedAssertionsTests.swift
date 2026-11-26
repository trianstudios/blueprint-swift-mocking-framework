import Testing
@testable import BlueprintMocking

private func timedFixture(in session: MockSession)
    -> (endpoint: SyncEndpoint<String, String>, selector: SessionCallSelector) {
    let scope = session.makeMock()
    let id = EndpointID("timed call")
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).willAnswer { $0 }
    let endpoint = SyncEndpoint(
        id: id, configuration: setup.finish(), failureReporter: FailureReporter { issue in
            Issue.record("Unexpected issue in timed assertion test: \(issue.message)")
        }, scope: scope
    )
    return (endpoint, SessionCallSelector(mockID: scope.id, endpoint: id))
}

@Test func RUN031_wholeIntervalRejectsSameTimeTransientViolation() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never.or(.exactly(2)), for: counted.selector,
                                             window: .until(.seconds(5)))
    // Both admissions are committed at the same clock instant before the reader runs.
    _ = counted.endpoint.invoke("violates")
    _ = counted.endpoint.invoke("restores")
    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    try #require(admissions.count == 2)
    #expect(admissions.map(\.elapsed) == [.zero, .zero])
    try session.advanceClock(by: .seconds(5))

    do {
        _ = try await wait.value()
        Issue.record("A later matching prefix must not hide an interval violation")
    } catch let error as SessionTimedObservationError {
        guard case .violated(let violation) = error else {
            Issue.record("Expected the first interval violation, got \(error)")
            return
        }
        #expect(violation.observed == 1)
        #expect(violation.elapsed == .zero)
        #expect(violation.watermark == admissions[0].ordinal)
        #expect(violation.epoch == snapshot.epoch)
    }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN032_interruptedWindowRestartsAndSurvivesALaterViolation() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never.or(.exactly(2)), for: counted.selector,
                                             window: .stable(.seconds(3), within: .seconds(10)))
    try session.advanceClock(by: .seconds(2))
    _ = counted.endpoint.invoke("interrupts the initial window")
    try session.advanceClock(by: .seconds(2))
    _ = counted.endpoint.invoke("starts the replacement window")
    try session.advanceClock(by: .seconds(4))
    _ = counted.endpoint.invoke("violates only after the replacement window matured")

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    try #require(admissions.count == 3)
    let result = try await wait.value()
    #expect(result.observed == 2)
    #expect(result.elapsed == .seconds(7))
    #expect(result.epoch == snapshot.epoch)
    #expect(result.watermark >= admissions[1].ordinal)
    #expect(result.watermark < admissions[2].ordinal)
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN031_anEventAtTheCutoffIsOutsideTheEndingInterval() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    try session.advanceClock(by: .seconds(2))
    let wait = try session.prepareTimedCount(.never, for: counted.selector, window: .until(.seconds(5)))

    try session.advanceClock(by: .seconds(5))
    _ = counted.endpoint.invoke("exactly at the cutoff")
    let cutoffAdmission = try #require(session.snapshot().events.first)
    #expect(cutoffAdmission.elapsed == .seconds(7))

    let result = try await wait.value()
    #expect(result.elapsed == .seconds(7))
    #expect(result.observed == 0)
    #expect(result.watermark < cutoffAdmission.ordinal)
}

@Test func RUN032_unstableObservationFailsAtItsOverallDeadline() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never, for: counted.selector,
                                             window: .stable(.seconds(3), within: .seconds(5)))
    try session.advanceClock(by: .seconds(1))
    _ = counted.endpoint.invoke("interrupts stability")
    try session.advanceClock(by: .seconds(4))

    await #expect(throws: SessionTimedObservationError.deadlineExceeded) { try await wait.value() }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN031_cancellingPreparedWaitUnregistersIt() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never, for: counted.selector, window: .until(.seconds(5)))
    #expect(session.withLock { $0.observationCount } == 1)

    let waiting = Task { try await wait.value() }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN032_prunedHistoryCannotProveStability() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never.or(.exactly(2)), for: counted.selector,
                                             window: .stable(.seconds(3), within: .seconds(10)))
    _ = counted.endpoint.invoke("unread violation")
    _ = counted.endpoint.invoke("unread restoration")
    try session.discardEvents(through: session.checkpoint())
    try session.advanceClock(by: .seconds(5))

    await #expect(throws: SessionCheckpointError.historyUnavailable) { try await wait.value() }
    await #expect(throws: SessionCheckpointError.historyUnavailable) {
        try await session.until(.exactly(2), for: counted.selector, for: .seconds(1))
    }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN031_epochResetInvalidatesThePreparedInterval() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never, for: counted.selector, window: .until(.seconds(5)))
    _ = try session.resetHistory()
    try session.advanceClock(by: .seconds(5))

    await #expect(throws: SessionCheckpointError.staleEpoch) { try await wait.value() }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN032_publicTimedAssertionsRejectInvalidDurations() async {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)

    await #expect(throws: SessionTimedObservationError.invalidDuration) {
        try await session.until(.never, for: counted.selector, for: .seconds(-1))
    }
    await #expect(throws: SessionTimedObservationError.invalidDuration) {
        try await session.stable(.never, for: counted.selector, for: .seconds(-1), within: .seconds(5))
    }
    await #expect(throws: SessionTimedObservationError.invalidDuration) {
        try await session.stable(.never, for: counted.selector, for: .seconds(6), within: .seconds(5))
    }
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN031_finishingBeforeTheCutoffCannotBeMaturedByALaterAdvance() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let wait = try session.prepareTimedCount(.never, for: counted.selector, window: .until(.seconds(5)))

    try session.advanceClock(by: .seconds(2))
    let finished = try session.finishIfQuiescent()
    try session.advanceClock(by: .seconds(5))

    await #expect(throws: SessionTimedObservationError.sessionFinished) { try await wait.value() }
    #expect(session.snapshot() == finished)
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test(.timeLimit(.minutes(1)))
func RUN032_idleContinuousClockCompletesItsStableWindow() async throws {
    let session = MockSession(clock: .continuous)
    let counted = timedFixture(in: session)
    let duration = Duration.milliseconds(10)

    let result = try await session.stable(.never, for: counted.selector, for: duration, within: .seconds(1))
    #expect(result.elapsed >= duration)
    #expect(result.observed == 0)
    #expect(result.epoch == session.snapshot().epoch)
    #expect(result.watermark == session.snapshot().watermark)
    #expect(session.withLock { $0.observationCount } == 0)
}

@Test func RUN032_stabilityMaturesAtOverallDeadlineBeforeEqualTimeViolation() async throws {
    let session = MockSession(clock: .manual)
    let counted = timedFixture(in: session)
    let unrelated = timedFixture(in: session)
    let boundary = Duration.seconds(3)
    let wait = try session.prepareTimedCount(.never, for: counted.selector,
                                             window: .stable(boundary, within: boundary))

    try session.advanceClock(by: .seconds(1))
    _ = unrelated.endpoint.invoke("included before the cutoff")
    let included = session.snapshot()
    try session.advanceClock(by: .seconds(2))
    _ = counted.endpoint.invoke("violates at the cutoff")
    let violatingAdmission = try #require(session.snapshot().events.first {
        $0.mockID == counted.selector.mockID && $0.phase == .admitted
    })
    #expect(violatingAdmission.elapsed == boundary)

    let result = try await wait.value()
    #expect(result.elapsed == boundary)
    #expect(result.observed == 0)
    #expect(result.epoch == included.epoch)
    #expect(result.watermark == included.watermark)
    #expect(result.watermark < violatingAdmission.ordinal)
}
