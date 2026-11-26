import Testing
import BlueprintMocking

private struct RetentionGate: Sendable {
    private let admission = AsyncStream<Void>.makeStream()
    private let resumption = AsyncStream<Void>.makeStream()

    func pause() async {
        admission.continuation.finish()
        for await _ in resumption.stream {}
    }

    func waitForAdmission() async {
        for await _ in admission.stream {}
    }

    func resume() { resumption.continuation.finish() }
}

private func pausedEndpoint(scope: MockScope, gate: RetentionGate, issues: Issues)
    -> AsyncThrowingEndpoint<String, String, ServiceError> {
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willAnswer { value async throws(ServiceError) in
        await gate.pause()
        return value
    }
    return AsyncThrowingEndpoint(id: EndpointID("paused"), configuration: stubs.finish(),
                                 failureReporter: issues.reporter, scope: scope)
}

private func recordEndpoint(_ name: String, scope: MockScope, issues: Issues) -> SyncEndpoint<String, String> {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    return SyncEndpoint(id: EndpointID(name), configuration: stubs.finish(),
                        failureReporter: issues.reporter, scope: scope)
}

@Test func RUN041_retentionDistinguishesArchivedOrdinalGapsFromPruning() async throws {
    let session = MockSession()
    let scope = session.makeMock()
    let issues = Issues()
    let gate = RetentionGate()
    defer { gate.resume() }
    let paused = pausedEndpoint(scope: scope, gate: gate, issues: issues)
    let early = recordEndpoint("early", scope: scope, issues: issues)
    let late = recordEndpoint("late", scope: scope, issues: issues)
    let running = Task { try await paused.invoke("detached") }
    await gate.waitForAdmission()
    let originalEpoch = session.snapshot().epoch
    _ = try session.resetHistory(.detachActive)
    let beforeCurrentEvents = session.checkpoint()
    _ = early.invoke("will be pruned")
    let afterEarly = session.checkpoint()

    gate.resume()
    #expect(try await running.value == "detached")
    let archived = try #require(session.snapshot(epoch: originalEpoch))
    let oldCompletion = try #require(archived.events.last)
    let atArchivedCompletion = session.checkpoint()
    #expect(oldCompletion.phase == .returned)
    #expect(afterEarly.watermark < atArchivedCompletion.watermark)
    #expect(atArchivedCompletion.watermark == oldCompletion.ordinal)

    _ = late.invoke("will be retained")
    let beforePrune = session.snapshot()
    let currentSuffix = Array(beforePrune.events.suffix(2))
    #expect(beforePrune.prunedThrough == nil)
    let firstRetained = try #require(currentSuffix.first)
    #expect(firstRetained.ordinal > atArchivedCompletion.watermark)
    #expect(try session.events(since: afterEarly) == currentSuffix)
    #expect(try session.events(since: atArchivedCompletion) == currentSuffix)

    try session.discardEvents(through: atArchivedCompletion)
    let pruned = session.snapshot()
    #expect(pruned.events == currentSuffix)
    #expect(pruned.prunedThrough == afterEarly.watermark)
    #expect(pruned.watermark == beforePrune.watermark)
    #expect(try session.events(since: afterEarly) == currentSuffix)
    #expect(try session.events(since: atArchivedCompletion) == currentSuffix)
    do {
        _ = try session.events(since: beforeCurrentEvents)
        Issue.record("Expected a history-unavailable replay error")
    } catch {
        #expect(error == .historyUnavailable)
    }

    try session.discardEvents(through: beforeCurrentEvents)
    try session.discardEvents(through: atArchivedCompletion)
    #expect(session.snapshot() == pruned)
    let archivedAfterPrune = try #require(session.snapshot(epoch: originalEpoch))
    #expect(archivedAfterPrune.events == archived.events)
    #expect(archivedAfterPrune.prunedThrough == archived.prunedThrough)
    #expect(archivedAfterPrune.watermark == pruned.watermark)

    let first = SessionCallSelector(mockID: scope.id, endpoint: EndpointID("early"))
    let last = SessionCallSelector(mockID: scope.id, endpoint: EndpointID("late"))
    let seenLate = SessionOrderResult.matched(currentSuffix.filter { $0.phase == .admitted })
    let originalOrder = SessionOrderResult.matched(beforePrune.events.filter { $0.phase == .admitted })
    #expect(beforePrune.matchOrder([first, last], mode: .strict) == originalOrder)
    #expect(pruned.matchOrder([last], mode: .strict) == seenLate)
    #expect(pruned.matchOrder([last], mode: .relative) == seenLate)
    #expect(pruned.matchOrder([first], mode: .strict) == .historyUnavailable)
    #expect(pruned.matchOrder([first], mode: .relative) == .historyUnavailable)
    #expect(pruned.matchOrder([first, last], mode: .relative) == .historyUnavailable)
    #expect(pruned.matchOrder([first, last], mode: .strict) == .historyUnavailable)
    #expect(pruned.matchOrder([], mode: .strict) == .matched([]))
    #expect(issues.values.isEmpty)
}

@Test func RUN041_pruningAnActiveAdmissionPreservesCompletion() async throws {
    let session = MockSession()
    let gate = RetentionGate()
    defer { gate.resume() }
    let issues = Issues()
    let endpoint = pausedEndpoint(scope: session.makeMock(), gate: gate, issues: issues)
    let running = Task { try await endpoint.invoke("value") }
    await gate.waitForAdmission()
    let admission = try #require(session.snapshot().events.first)
    let checkpoint = session.checkpoint()

    try session.discardEvents(through: checkpoint)
    let pruned = session.snapshot()
    #expect(pruned.events.isEmpty)
    #expect(pruned.prunedThrough == admission.ordinal)
    #expect(pruned.activeInvocationCount == 1)
    #expect(endpoint.invocations.count == 1)
    #expect(try session.events(since: checkpoint).isEmpty)

    gate.resume()
    #expect(try await running.value == "value")
    let suffix = try session.events(since: checkpoint)
    #expect(suffix.count == 1)
    let completion = try #require(suffix.first)
    #expect(completion.invocationID == admission.invocationID)
    #expect(completion.phase == .returned)
    #expect(session.snapshot().activeInvocationCount == 0)
    #expect(issues.values.isEmpty)
}

@Test func RUN041_pruningRejectsForeignStaleAndFinishedCheckpoints() throws {
    let session = MockSession()
    let foreign = MockSession().checkpoint()
    let original = session.checkpoint()
    do {
        try session.discardEvents(through: foreign)
        Issue.record("Expected a foreign-session checkpoint error")
    } catch {
        #expect(error == .foreignSession)
    }

    _ = try session.resetHistory()
    do {
        try session.discardEvents(through: original)
        Issue.record("Expected a stale-epoch checkpoint error")
    } catch {
        #expect(error == .staleEpoch)
    }

    let issues = Issues()
    let endpoint = recordEndpoint("final", scope: session.makeMock(), issues: issues)
    _ = endpoint.invoke("keep final evidence")
    let checkpoint = session.checkpoint()
    let finished = try session.finishIfQuiescent()
    do {
        try session.discardEvents(through: checkpoint)
        Issue.record("Expected a finished-session mutation error")
    } catch {
        #expect(error == .finishedSession)
    }
    #expect(session.snapshot() == finished)
    #expect(try session.events(since: checkpoint).isEmpty)
    #expect(issues.values.isEmpty)
}
