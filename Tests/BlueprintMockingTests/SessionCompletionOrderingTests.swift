import Testing
import BlueprintMocking

private struct CompletionOrderGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func pause() async {
        entered.continuation.finish()
        for await _ in released.stream {}
    }

    func waitForAdmission() async {
        for await _ in entered.stream {}
    }

    func resume() { released.continuation.finish() }
}

private func completionSelector(_ scope: MockScope, _ endpoint: String) -> SessionCallSelector {
    SessionCallSelector(mockID: scope.id, endpoint: EndpointID(endpoint))
}

private func completionOrderEndpoint(_ name: String, scope: MockScope, issues: Issues)
    -> SyncEndpoint<String, String> {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    return SyncEndpoint(id: EndpointID(name), configuration: stubs.finish(),
                        failureReporter: issues.reporter, scope: scope)
}

private func pausedCompletionEndpoint(
    _ name: String, scope: MockScope, gate: CompletionOrderGate, issues: Issues
) -> AsyncThrowingEndpoint<String, String, ServiceError> {
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willAnswer { value async throws(ServiceError) in
        await gate.pause()
        return value
    }
    return AsyncThrowingEndpoint(id: EndpointID(name), configuration: stubs.finish(),
                                 failureReporter: issues.reporter, scope: scope)
}

@Test func RUN029_completionBeforeStartDiffersFromAdmissionAndCompletionOrder() async throws {
    let session = MockSession()
    let firstScope = session.makeMock()
    let secondScope = session.makeMock()
    let gate = CompletionOrderGate()
    defer { gate.resume() }
    let issues = Issues()
    let first = pausedCompletionEndpoint("first", scope: firstScope, gate: gate, issues: issues)
    let second = completionOrderEndpoint("second", scope: secondScope, issues: issues)
    let firstSelector = completionSelector(firstScope, "first")
    let secondSelector = completionSelector(secondScope, "second")
    let running = Task { try await first.invoke("paused") }

    await gate.waitForAdmission()
    _ = second.invoke("during first")
    let inFlight = session.snapshot()
    let admissions = inFlight.events.filter { $0.phase == .admitted }
    #expect(inFlight.matchOrder([firstSelector, secondSelector], mode: .relative) == .matched(admissions))
    #expect(inFlight.matchCompletion(of: firstSelector, beforeStartOf: secondSelector) == .notMatched)

    gate.resume()
    #expect(try await running.value == "paused")
    let overlapped = session.snapshot()
    let completions = overlapped.events.filter { $0.phase == .returned }
    #expect(overlapped.matchOrder([secondSelector, firstSelector], mode: .relative, phase: .returned)
        == .matched(completions))
    #expect(overlapped.matchCompletion(of: firstSelector, beforeStartOf: secondSelector, phase: .returned)
        == .notMatched)
    #expect(overlapped.matchCompletion(of: secondSelector, beforeStartOf: firstSelector, phase: .returned)
        == .notMatched)

    _ = second.invoke("after first")
    let later = session.snapshot()
    let completion = try #require(completions.last)
    let admission = try #require(later.events.last(where: { $0.phase == .admitted }))
    #expect(later.matchCompletion(of: firstSelector, beforeStartOf: secondSelector, phase: .returned)
        == .matched([completion, admission]))
    #expect(overlapped.matchCompletion(of: firstSelector, beforeStartOf: secondSelector) == .notMatched)
    #expect(completion.ordinal < admission.ordinal)
    #expect(issues.values.isEmpty)
}

@Test func RUN029_completionBeforeStartAcceptsExplicitThrowingOutcome() throws {
    let session = MockSession()
    let failedScope = session.makeMock()
    let nextScope = session.makeMock()
    let issues = Issues()
    let stubs = SyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willThrow(.offline)
    let failed = SyncThrowingEndpoint(id: EndpointID("fallible"), configuration: stubs.finish(),
                                      failureReporter: issues.reporter, scope: failedScope)
    let next = completionOrderEndpoint("next", scope: nextScope, issues: issues)
    #expect(throws: ServiceError.offline) { try failed.invoke("failure") }
    _ = next.invoke("next")

    let snapshot = session.snapshot()
    let first = completionSelector(failedScope, "fallible")
    let second = completionSelector(nextScope, "next")
    let throwing = try #require(snapshot.events.first(where: { $0.phase == .threw }))
    let started = try #require(snapshot.events.last(where: { $0.phase == .admitted }))
    let expected = SessionOrderResult.matched([throwing, started])
    #expect(snapshot.matchCompletion(of: first, beforeStartOf: second, phase: .threw) == expected)
    #expect(snapshot.matchCompletion(of: first, beforeStartOf: second) == expected)
    #expect(snapshot.matchCompletion(of: first, beforeStartOf: second, phase: .returned) == .notMatched)
    #expect(snapshot.matchCompletion(of: first, beforeStartOf: second, phase: .terminated) == .notMatched)
    #expect(issues.values.isEmpty)
}

@Test func RUN029_completionBeforeStartSelectsDistinctRepeatedInvocations() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let issues = Issues()
    let endpoint = completionOrderEndpoint("same", scope: scope, issues: issues)
    let selector = completionSelector(scope, "same")
    _ = endpoint.invoke("first")
    #expect(session.snapshot().matchCompletion(of: selector, beforeStartOf: selector) == .notMatched)
    _ = endpoint.invoke("second")
    _ = endpoint.invoke("third")

    let snapshot = session.snapshot()
    let completion = try #require(snapshot.events.first(where: { $0.phase == .returned }))
    let admission = try #require(snapshot.events.first(where: { $0.phase == .admitted && $0.ordinal > completion.ordinal }))
    #expect(snapshot.matchCompletion(of: selector, beforeStartOf: selector) == .matched([completion, admission]))
    #expect(completion.invocationID != admission.invocationID)
    #expect(issues.values.isEmpty)
}

@Test func RUN029_completionBeforeStartDistinguishesPrunedMissesFromRetainedProof() throws {
    let session = MockSession()
    let firstScope = session.makeMock()
    let secondScope = session.makeMock()
    let issues = Issues()
    let first = completionOrderEndpoint("first", scope: firstScope, issues: issues)
    let second = completionOrderEndpoint("second", scope: secondScope, issues: issues)
    let a = completionSelector(firstScope, "first")
    let b = completionSelector(secondScope, "second")

    _ = first.invoke("old")
    let discard = session.checkpoint()
    _ = second.invoke("old")
    let full = session.snapshot()
    let original = full.events.filter { ($0.mockID == firstScope.id && $0.phase == .returned)
        || ($0.mockID == secondScope.id && $0.phase == .admitted) }
    #expect(full.matchCompletion(of: a, beforeStartOf: b) == .matched(original))
    try session.discardEvents(through: discard)
    #expect(session.snapshot().matchCompletion(of: a, beforeStartOf: b) == .historyUnavailable)
    #expect(full.matchCompletion(of: a, beforeStartOf: b) == .matched(original))

    _ = first.invoke("retained")
    _ = second.invoke("retained")
    let suffix = session.snapshot()
    let completion = try #require(suffix.events.first(where: { $0.mockID == firstScope.id && $0.phase == .returned }))
    let start = try #require(suffix.events.last(where: { $0.mockID == secondScope.id && $0.phase == .admitted }))
    #expect(suffix.matchCompletion(of: a, beforeStartOf: b) == .matched([completion, start]))
    #expect(issues.values.isEmpty)
}

@Test func RUN029_archivedCompletionCannotPairWithCurrentStart() async throws {
    let session = MockSession()
    let other = MockSession()
    let firstScope = session.makeMock()
    let secondScope = session.makeMock()
    let foreignScope = other.makeMock()
    let gate = CompletionOrderGate()
    defer { gate.resume() }
    let issues = Issues()
    let first = pausedCompletionEndpoint("first", scope: firstScope, gate: gate, issues: issues)
    let second = completionOrderEndpoint("second", scope: secondScope, issues: issues)
    let a = completionSelector(firstScope, "first")
    let b = completionSelector(secondScope, "second")
    let foreign = completionSelector(foreignScope, "first")
    let running = Task { try await first.invoke("old epoch") }

    await gate.waitForAdmission()
    let oldEpoch = session.snapshot().epoch
    _ = try session.resetHistory(.detachActive)
    gate.resume()
    #expect(try await running.value == "old epoch")
    _ = second.invoke("new epoch")

    let archived = try #require(session.snapshot(epoch: oldEpoch))
    #expect(archived.events.last?.phase == .returned)
    let current = session.snapshot()
    #expect(current.matchCompletion(of: a, beforeStartOf: b) == .notMatched)
    #expect(current.matchCompletion(of: foreign, beforeStartOf: b) == .foreignMock(foreignScope.id))
    #expect(current.matchCompletion(of: a, beforeStartOf: foreign) == .foreignMock(foreignScope.id))
    #expect(issues.values.isEmpty)
}
