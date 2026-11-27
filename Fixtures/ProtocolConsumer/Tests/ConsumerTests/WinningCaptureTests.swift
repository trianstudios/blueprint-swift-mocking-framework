import Dispatch
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

@Test(.timeLimit(.minutes(1)))
func RUN009_generatedWinningRulesCaptureOnceThroughReentryAndConcurrency() async {
    let session = MockSession()
    let selected = ArgumentCaptor<String>(session: session)
    let overlapping = ArgumentCaptor<String>(session: session)
    let negated = ArgumentCaptor<String>(session: session)
    let nested = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any)
            .capturing(into: selected, projecting: { "nested-\($0)" })
            .willReturn("nested")
    }
    let outer = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any)
            .capturing(into: overlapping, projecting: {
                Issue.record("A shadowed rule must not project")
                return $0
            })
            .willReturn("shadowed")
        stubs.greeting(for: .prefix("call-"))
            .capturing(into: selected, projecting: { "outer-\($0)" })
            .willAnswer { value in
                #expect(selected.captures.contains { $0.value == "outer-\(value)" })
                return nested.greeting(for: value)
            }
        stubs.greeting(for: .prefix("call-").not())
            .capturing(into: negated, projecting: {
                Issue.record("A failed negated matcher must not project")
                return $0
            })
            .willReturn("negated")
    }

    let names = (0..<24).map { "call-\($0)" }
    await withTaskGroup(of: String.self) { group in
        for name in names { group.addTask { outer.greeting(for: name) } }
        for await answer in group { #expect(answer == "nested") }
    }

    let captures = selected.captures
    let admissions = session.snapshot().events.filter { $0.phase == .admitted }
    #expect(captures.count == names.count * 2)
    #expect(captures.map(\.invocation) == admissions)
    #expect(Set(captures.map(\.invocation.invocationID)).count == captures.count)
    #expect(Set(captures.map(\.value)) == Set(names.flatMap { ["outer-\($0)", "nested-\($0)"] }))
    #expect(overlapping.captures.isEmpty)
    #expect(negated.captures.isEmpty)
}

@Test func RUN009_failedSelectionAndUncapturedStubsPublishNothing() {
    let session = MockSession()
    let captor = ArgumentCaptor<Int>(session: session)
    let setup = SyncStubbing<String, String>()
    setup.matching(.equal("captured"))
        .capturing(into: captor, projecting: { $0.count })
        .willReturn("supported")
    setup.matching(.equal("plain")).willReturn("ordinary")
    let endpoint = SyncEndpoint(
        id: EndpointID("capture"), configuration: setup.finish(),
        failureReporter: FailureReporter { _ in }, scope: session.makeMock(),
        fallback: { _ in "fallback" }
    )

    #expect(endpoint.invoke("unknown") == "fallback")
    #expect(endpoint.invoke("plain") == "ordinary")
    #expect(captor.captures.isEmpty)
    #expect(endpoint.invoke("captured") == "supported")
    #expect(captor.captures.map(\.value) == [8])
    #expect(captor.captures.last?.invocation.invocationID == endpoint.invocations.last?.sessionInvocationID)
}

private struct WinnerCaptureGate: Sendable {
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.continuation.finish()
        release.wait()
    }

    func waitUntilEntered() async {
        for await _ in entered.stream {}
    }

    func resume() { release.signal() }
}

@Test(.timeLimit(.minutes(1)))
func RUN009_resetRetiresWinningCapturesAndDropsLateOldPublication() async throws {
    let session = MockSession()
    let captor = ArgumentCaptor<String>(session: session)
    let gate = WinnerCaptureGate()
    defer { gate.resume() }
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).capturing(into: captor, projecting: { value in
        _ = session.snapshot() // Reentry demonstrates the projector runs outside coordinator locks.
        if value == "late" { gate.pause() }
        return String(value.prefix(1))
    }).willAnswer { $0 }
    // A projected-sync endpoint uses the same configured winning policy.
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("reset-capture"), configuration: setup.finish(),
        projection: InvocationProjection(argument: { $0.count }, result: { $0.count }),
        failureReporter: .swiftTesting, scope: session.makeMock()
    )

    #expect(endpoint.invoke("before") == "before")
    let old = captor.captures
    #expect(old.map(\.value) == ["b"])
    let completion = AsyncStream<String>.makeStream()
    DispatchQueue.global().async {
        completion.continuation.yield(endpoint.invoke("late"))
        completion.continuation.finish()
    }
    await gate.waitUntilEntered()
    let fresh = try session.resetHistory(.detachActive)
    #expect(captor.captures.isEmpty)
    gate.resume()
    var replies: [String] = []
    for await reply in completion.stream { replies.append(reply) }
    #expect(replies == ["late"])
    #expect(captor.captures.isEmpty)
    #expect(old.map(\.value) == ["b"])

    #expect(endpoint.invoke("current") == "current")
    #expect(captor.captures.map(\.value) == ["c"])
    #expect(captor.captures.first?.invocation.epoch == fresh)
}

private final class RetiredCaptureValue: Sendable {
    private let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

@Test(.timeLimit(.minutes(1)))
func RUN009_winningCapturePayloadCanReenterSessionWhenResetReleasesIt() async throws {
    let session = MockSession()
    let released = AsyncStream<SessionEpoch>.makeStream()
    let captor = ArgumentCaptor<RetiredCaptureValue>(session: session)
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).capturing(into: captor, projecting: { _ in
        RetiredCaptureValue {
            released.continuation.yield(session.snapshot().epoch)
            released.continuation.finish()
        }
    }).willReturn("response")
    let endpoint = SyncEndpoint(
        id: EndpointID("retirement"), configuration: setup.finish(),
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    _ = endpoint.invoke("argument")
    #expect(captor.captures.count == 1)

    let current = try session.resetHistory()
    var releasedEpochs: [SessionEpoch] = []
    for await epoch in released.stream { releasedEpochs.append(epoch) }
    #expect(releasedEpochs == [current])
    #expect(captor.captures.isEmpty)
}

@Test func RUN007_generatedVerificationReportsOnlyExplicitMatcherDescriptions() {
    let reports = StoredProperty<[MockIssue]>([])
    let mock = UserRepositoryMock(failureReporter: FailureReporter { issue in
        reports.set(reports.get() + [issue])
    }) { stubs in
        stubs.greeting(for: .any).willReturn("hello")
    }
    #expect(mock.greeting(for: "private-customer") == "hello")

    let named = Matcher<String>.satisfying { _ in true }.named("known account")
        .and(.equal("private-comparison"))
    #expect(!mock.verify.greeting(for: named).wasCalled(.once).passed)
    #expect(reports.get().map(\.message) == [
        "Expected exactly 1 calls; observed 0\nMatcher and(known account, unnamed matcher)",
    ])
}
