import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

private actor ScenarioAnswerGate {
    let entered: AsyncStream<Bool>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ entered: AsyncStream<Bool>.Continuation) { self.entered = entered }

    func pause() async {
        guard !released, continuation == nil else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.yield(true)
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Test(.timeLimit(.minutes(1)))
func RUN015_generatedScenarioReservesOnceAndIgnoresStaleCompletionAfterABA() async throws {
    let session = MockSession()
    let entry = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let gate = ScenarioAnswerGate(entry.continuation)
    defer { Task { await gate.release() } }

    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.fetchUser(id: .any).willScenario(initial: "ready", transitions: [
            .init(from: "ready", when: .equal("take"), reserving: "running",
                  answer: .answering { _ async throws(RepositoryError) in
                      #expect(session.snapshot().activeInvocationCount == 1)
                      await gate.pause()
                      return "original answer"
                  }, onReturn: "completed"),
            .init(from: "running", when: .equal("reopen"), reserving: "ready",
                  answer: .returning("reopened")),
            .init(from: "ready", when: .equal("replace"), reserving: "running",
                  answer: .returning("replacement")),
            .init(from: "running", when: .equal("inspect"), reserving: "running",
                  answer: .returning("latest running state")),
        ], onConflict: .offline)
    }
    let repository: any UserRepository = mock
    let original = Task {
        defer { entry.continuation.finish() }
        return try await repository.fetchUser(id: "take")
    }
    var entries = entry.stream.makeAsyncIterator()
    let entered = await entries.next()
    try #require(entered == true)
    let admitted = try #require(session.snapshot().events.first)
    #expect(admitted.phase == .admitted)

    await #expect(throws: RepositoryError.offline) {
        try await repository.fetchUser(id: "take")
    }
    #expect(try await repository.fetchUser(id: "reopen") == "reopened")
    #expect(try await repository.fetchUser(id: "replace") == "replacement")
    #expect(session.snapshot().activeInvocationCount == 1)

    await gate.release()
    #expect(try await original.value == "original answer")
    #expect(try await repository.fetchUser(id: "inspect") == "latest running state")

    let snapshot = session.snapshot()
    #expect(snapshot.activeInvocationCount == 0)
    #expect(snapshot.events.filter { $0.invocationID == admitted.invocationID }.map(\.phase) == [.admitted, .returned])
    #expect(snapshot.events.filter { $0.phase == .threw }.count == 1)
    #expect(mock.verify.fetchUser(id: .equal("take"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetchUser(id: .equal("take"), phase: .threw).wasCalled(.once).passed)
}

@Test func RUN015_generatedScenarioPublishesCurrentSuccessfulCompletion() async throws {
    let session = MockSession(clock: .manual)
    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.fetchUser(id: .any).willScenario(initial: "ready", transitions: [
            .init(from: "ready", when: .equal("take"), reserving: "running",
                  answer: .returning("taken"), onReturn: "complete"),
            .init(from: "complete", when: .equal("inspect"), reserving: "complete",
                  answer: .returning("complete")),
        ], onConflict: .offline)
    }
    let repository: any UserRepository = mock
    #expect(try await repository.fetchUser(id: "take") == "taken")
    _ = try session.resetHistoryAndSequences()
    #expect(try await repository.fetchUser(id: "inspect") == "complete")
}

private func scenarioBase(_ label: String) -> AsyncThrowingConfiguration<String, String, RepositoryError> {
    let setup = AsyncThrowingStubbing<String, String, RepositoryError>()
    setup.matching(.any).willReturn(label)
    return setup.finish()
}

private func scenarioOverlay(
    held: ScenarioAnswerGate, matching matcher: Matcher<String> = .any
) -> AsyncThrowingConfiguration<String, String, RepositoryError> {
    let setup = AsyncThrowingStubbing<String, String, RepositoryError>()
    setup.matching(matcher).willScenario(initial: "ready", transitions: [
        .init(from: "ready", when: .equal("take"), reserving: "running",
              answer: .answering { _ async throws(RepositoryError) in
                  await held.pause()
                  return "first answer"
              }, onReturn: "completed"),
        .init(from: "running", when: .equal("inspect"), reserving: "running",
              answer: .returning("running")),
        .init(from: "completed", when: .equal("inspect"), reserving: "completed",
              answer: .returning("completed")),
    ], onConflict: .offline)
    return setup.finish()
}

@Test(.timeLimit(.minutes(1)))
func RUN015_liveOverlayCompletionSurvivesBaseOnlyReplacement() async throws {
    let session = MockSession()
    let entered = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let gate = ScenarioAnswerGate(entered.continuation)
    defer { Task { await gate.release() } }
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("scenario-scope-base-revision"), configuration: scenarioBase("original base"),
        failureReporter: .swiftTesting, scope: session.makeMock()
    )

    try await endpoint.withScopedConfiguration(scenarioOverlay(held: gate)) {
        let first = Task {
            defer { entered.continuation.finish() }
            return try await endpoint.invoke("take")
        }
        var entries = entered.stream.makeAsyncIterator()
        let didEnter = await entries.next()
        try #require(didEnter == true)
        let original = try #require(session.snapshot().events.first)
        let revision = endpoint.replaceConfiguration(scenarioBase("changed base"))
        #expect(revision != original.configurationRevision)

        await gate.release()
        #expect(try await first.value == "first answer")
        #expect(try await endpoint.invoke("inspect") == "completed")
        let terminals = session.snapshot().events.filter {
            $0.invocationID == original.invocationID && $0.phase == .returned
        }
        let terminal = try #require(terminals.first)
        #expect(terminal.configurationRevision == original.configurationRevision)
    }
    #expect(try await endpoint.invoke("inspect") == "changed base")
}

@Test(.timeLimit(.minutes(1)))
func RUN015_closedOverlayRejectsPendingCompletionOnItsPinnedScenario() async throws {
    let session = MockSession()
    let entered = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let probeEntered = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let gate = ScenarioAnswerGate(entered.continuation)
    let releaseProbe = DispatchSemaphore(value: 0)
    defer { Task { await gate.release() } }
    defer { releaseProbe.signal() }
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("scenario-scope-exit"), configuration: scenarioBase("base"),
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let overlay = scenarioOverlay(held: gate, matching: Matcher { input in
        guard input == "inspect" else { return true }
        probeEntered.continuation.yield(true)
        return releaseProbe.wait(timeout: .now() + .seconds(15)) == .success
    })

    let (first, probe) = try await endpoint.withScopedConfiguration(overlay) {
        let first = Task {
            defer { entered.continuation.finish() }
            return try await endpoint.invoke("take")
        }
        var entries = entered.stream.makeAsyncIterator()
        let didEnter = await entries.next()
        try #require(didEnter == true)
        let probe = Task {
            defer { probeEntered.continuation.finish() }
            return try await endpoint.invoke("inspect")
        }
        var probes = probeEntered.stream.makeAsyncIterator()
        let didProbeEnter = await probes.next()
        try #require(didProbeEnter == true)
        #expect(session.snapshot().activeInvocationCount == 2)
        return (first, probe)
    }

    // The scope has closed, but both admissions hold the same pinned plan.
    await gate.release()
    #expect(try await first.value == "first answer")
    releaseProbe.signal()
    #expect(try await probe.value == "running")
    #expect(try await endpoint.invoke("inspect") == "base")
    #expect(session.snapshot().activeInvocationCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func RUN015_detachedCompletionAndReusablePlanPreserveIndependentCursors() async throws {
    let session = MockSession()
    let entered = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let gate = ScenarioAnswerGate(entered.continuation)
    defer { Task { await gate.release() } }
    let sharedPlan = scenarioOverlay(held: gate)
    let original = AsyncThrowingEndpoint(
        id: EndpointID("scenario-original"), configuration: sharedPlan,
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let independent = AsyncThrowingEndpoint(
        id: EndpointID("scenario-independent"), configuration: sharedPlan,
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let first = Task {
        defer { entered.continuation.finish() }
        return try await original.invoke("take")
    }
    var entries = entered.stream.makeAsyncIterator()
    let didEnter = await entries.next()
    try #require(didEnter == true)
    let admitted = try #require(session.snapshot().events.first)
    await #expect(throws: RepositoryError.offline) { try await independent.invoke("inspect") }
    let newEpoch = try session.resetHistory(.detachActive)
    #expect(newEpoch != admitted.epoch)
    await gate.release()
    #expect(try await first.value == "first answer")
    #expect(try await original.invoke("inspect") == "running")
    #expect(try await independent.invoke("take") == "first answer")
    #expect(try await independent.invoke("inspect") == "completed")
    let archived = try #require(session.snapshot(epoch: admitted.epoch))
    #expect(archived.events.filter { $0.invocationID == admitted.invocationID }.map(\.phase) == [.admitted, .returned])
    #expect(!session.snapshot().events.contains { $0.invocationID == admitted.invocationID })
}
