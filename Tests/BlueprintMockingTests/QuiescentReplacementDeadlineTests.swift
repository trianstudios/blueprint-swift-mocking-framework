import Testing
@testable import BlueprintMocking

private struct PausedReplacementSibling: Sendable {
    private let admission = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let release = AsyncStream<Void>.makeStream()
    let endpoint: AsyncEndpoint<Void, Void>

    init(session: MockSession) {
        let entered = admission.continuation
        let releases = release.stream
        let setup = AsyncStubbing<Void, Void>()
        setup.matching(.any).willAnswer { _ in
            entered.yield(())
            entered.finish()
            var gate = releases.makeAsyncIterator()
            _ = await gate.next()
        }
        endpoint = AsyncEndpoint(
            id: EndpointID("paused sibling"), configuration: setup.finish(),
            failureReporter: FailureReporter { _ in Issue.record("Unexpected sibling failure") },
            scope: session.makeMock()
        )
    }

    func waitForAdmission() async throws {
        var iterator = admission.stream.makeAsyncIterator()
        try #require(await iterator.next() != nil)
    }

    func resume() { release.continuation.finish() }
}

private enum DeadlineReplacementFixtureError: Error {
    case registrationNotObserved(expected: Int)
}

private func waitForReplacements(_ expected: Int, in session: MockSession) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while session.withLock({ $0.quiescentReplacementCount }) != expected {
        try Task.checkCancellation()
        guard ContinuousClock.now < end else {
            throw DeadlineReplacementFixtureError.registrationNotObserved(expected: expected)
        }
        await Task.yield()
    }
}

private func deadlinePlan(_ value: String) -> AsyncThrowingConfiguration<String, String, ServiceError> {
    let setup = AsyncThrowingStubbing<String, String, ServiceError>()
    setup.matching(.any).willReturn(value)
    return setup.finish()
}

private func makeDeadlineEndpoint(
    _ scope: MockScope, name: String = "deadline replacement"
) -> AsyncThrowingEndpoint<String, String, ServiceError> {
    AsyncThrowingEndpoint(
        id: EndpointID(name), configuration: deadlinePlan("old"),
        failureReporter: FailureReporter { _ in Issue.record("Unexpected endpoint failure") },
        scope: scope
    )
}

@Test(.timeLimit(.minutes(1)))
func RUN035_replacementExpiresAtTheExclusiveDeadlineWithoutWaitingForDrain() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = makeDeadlineEndpoint(session.makeMock())
    let sibling = PausedReplacementSibling(session: session)
    let held = Task { await sibling.endpoint.invoke(()) }
    defer { sibling.resume() }
    try await sibling.waitForAdmission()

    let update = Task {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("new"), within: .seconds(5))
    }
    defer { update.cancel() }
    try await waitForReplacements(1, in: session)

    try session.advanceClock(by: .seconds(5))
    #expect(session.withLock { $0.quiescentReplacementCount } == 0)
    await #expect(throws: QuiescentConfigurationWaitError.deadlineExceeded) { try await update.value }
    #expect(session.snapshot().activeInvocationCount == 1)

    sibling.resume()
    await held.value
    #expect(try await endpoint.invoke("after the deadline") == "old")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [0])
}

@Test(.timeLimit(.minutes(1)))
func RUN035_idleTransitionPublishesBeforeTheNextAdmissionAndBeforeWaiterDelivery() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = makeDeadlineEndpoint(session.makeMock())
    let sibling = session.makeMock()
    let admission = session.withLock {
        $0.admit(mockID: sibling.id, endpoint: EndpointID("held metadata"),
                 configurationRevision: RuleRevision(rawValue: 0))
    }
    let update = Task {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("new"), within: .seconds(5))
    }
    defer { update.cancel() }
    try await waitForReplacements(1, in: session)

    try session.advanceClock(by: .seconds(5) - .nanoseconds(1))
    // Hold the off-lock delivery so the suspended task cannot perform the replacement.
    let terminal = session.withLock { $0.complete(admission.invocationID, phase: .returned) }
    let delivery = try #require(terminal.delivery)
    var published = false
    defer { if !published { delivery.publish() } }
    #expect(session.withLock { $0.quiescentReplacementCount } == 0)
    #expect(try await endpoint.invoke("before waiter delivery") == "new")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [1])

    // Neither late delivery nor cancellation can undo a committed revision.
    try session.advanceClock(by: .nanoseconds(1))
    update.cancel()
    published = true
    delivery.publish()
    #expect(try await update.value.rawValue == 1)
}

@Test(.timeLimit(.minutes(1)))
func RUN035_cancellingARegisteredReplacementLeavesThePlanUnchanged() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = makeDeadlineEndpoint(session.makeMock())
    let sibling = PausedReplacementSibling(session: session)
    let held = Task { await sibling.endpoint.invoke(()) }
    defer { sibling.resume() }
    try await sibling.waitForAdmission()

    let update = Task {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("new"), within: .seconds(5))
    }
    defer { update.cancel() }
    try await waitForReplacements(1, in: session)

    update.cancel()
    await #expect(throws: CancellationError.self) { try await update.value }
    #expect(session.withLock { $0.quiescentReplacementCount } == 0)
    sibling.resume()
    await held.value
    #expect(try await endpoint.invoke("after cancellation") == "old")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [0])
}

@Test(.timeLimit(.minutes(1)))
func RUN035_detachedResetInvalidatesOnlyEpochBoundWaitingReplacements() async throws {
    let session = MockSession(clock: .manual)
    let bound = makeDeadlineEndpoint(session.makeEpochBoundMock(), name: "epoch-bound")
    let unbound = makeDeadlineEndpoint(session.makeMock(), name: "unbound")
    let sibling = PausedReplacementSibling(session: session)
    let held = Task { await sibling.endpoint.invoke(()) }
    defer { sibling.resume() }
    try await sibling.waitForAdmission()

    let boundUpdate = Task {
        try await bound.replaceConfigurationWhenQuiescent(deadlinePlan("bound new"), within: .seconds(5))
    }
    let unboundUpdate = Task {
        try await unbound.replaceConfigurationWhenQuiescent(deadlinePlan("unbound new"), within: .seconds(5))
    }
    defer {
        boundUpdate.cancel()
        unboundUpdate.cancel()
    }
    try await waitForReplacements(2, in: session)

    let originalEpoch = session.snapshot().epoch
    let currentEpoch = try session.resetHistory(.detachActive)
    await #expect(throws: QuiescentConfigurationError.staleScope) { try await boundUpdate.value }
    #expect(session.withLock { $0.quiescentReplacementCount } == 1)
    #expect(session.snapshot().activeInvocationCount == 0)
    #expect(session.snapshot(epoch: originalEpoch)?.activeInvocationCount == 1)

    sibling.resume()
    await held.value
    #expect(try await unboundUpdate.value.rawValue == 1)
    #expect(try await unbound.invoke("in the current epoch") == "unbound new")
    #expect(unbound.invocations.map(\.epoch) == [currentEpoch])
    // The unrestricted control exposes the next revision without admitting stale work.
    #expect(bound.replaceConfiguration(deadlinePlan("control")).rawValue == 1)
}

@Test
func RUN035_waitingReplacementRejectsInvalidWindowsAndFinishedSessions() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = makeDeadlineEndpoint(session.makeMock())
    let replacement = deadlinePlan("new")

    for timeout: Duration in [.zero, .nanoseconds(-1)] {
        await #expect(throws: QuiescentConfigurationWaitError.invalidDuration) {
            try await endpoint.replaceConfigurationWhenQuiescent(replacement, within: timeout)
        }
    }

    let updated = try await endpoint.replaceConfigurationWhenQuiescent(replacement, within: .seconds(1))
    #expect(updated.rawValue == 1)
    #expect(try await endpoint.invoke("idle replacement") == "new")

    let closed = try session.finishIfQuiescent()
    await #expect(throws: QuiescentConfigurationError.finishedSession) {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("too late"), within: .seconds(1))
    }
    #expect(session.withLock { $0.quiescentReplacementCount } == 0)
    #expect(session.snapshot() == closed)
    #expect(endpoint.replaceConfiguration(replacement).rawValue == 2)
}

@Test(.timeLimit(.minutes(1)))
func RUN035_continuousClockExpiresARegisteredReplacementWithoutCompletion() async throws {
    let session = MockSession()
    let endpoint = makeDeadlineEndpoint(session.makeMock())
    let sibling = PausedReplacementSibling(session: session)
    let held = Task { await sibling.endpoint.invoke(()) }
    defer { sibling.resume() }
    try await sibling.waitForAdmission()

    await #expect(throws: QuiescentConfigurationWaitError.deadlineExceeded) {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("new"), within: .milliseconds(20))
    }
    #expect(session.withLock { $0.quiescentReplacementCount } == 0)
    #expect(session.snapshot().activeInvocationCount == 1)
    sibling.resume()
    await held.value
    #expect(try await endpoint.invoke("after the deadline") == "old")
}

@Test(.timeLimit(.minutes(1)))
func RUN035_multipleWaitingReplacementsPublishInRegistrationOrder() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = makeDeadlineEndpoint(session.makeMock())
    let sibling = PausedReplacementSibling(session: session)
    let held = Task { await sibling.endpoint.invoke(()) }
    defer { sibling.resume() }
    try await sibling.waitForAdmission()

    let first = Task {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("first"), within: .seconds(1))
    }
    defer { first.cancel() }
    try await waitForReplacements(1, in: session)
    let second = Task {
        try await endpoint.replaceConfigurationWhenQuiescent(deadlinePlan("second"), within: .seconds(1))
    }
    defer { second.cancel() }
    try await waitForReplacements(2, in: session)

    sibling.resume()
    await held.value
    #expect(try await first.value.rawValue == 1)
    #expect(try await second.value.rawValue == 2)
    #expect(try await endpoint.invoke("next admission") == "second")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [2])
}
