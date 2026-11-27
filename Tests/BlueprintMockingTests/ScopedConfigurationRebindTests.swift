import BlueprintMocking
import Testing

private enum RebindRuleFailure: Error {
    case invalidScope
}

private typealias RebindEndpoint = AsyncThrowingEndpoint<Int, String, RebindRuleFailure>
private typealias RebindStubbing = AsyncThrowingStubbing<Int, String, RebindRuleFailure>

private func reboundPlan(_ configure: (RebindStubbing) -> Void)
    -> AsyncThrowingConfiguration<Int, String, RebindRuleFailure> {
    let stubs = RebindStubbing()
    configure(stubs)
    return stubs.finish()
}

private func reboundEndpoint(
    scope: MockScope, reporter: FailureReporter = FailureReporter { Issue.record("\($0.message)") }
) -> RebindEndpoint {
    RebindEndpoint(
        id: EndpointID("rebind.fetch"), configuration: reboundPlan { $0.matching(.any).willReturn("base") },
        failureReporter: reporter, scope: scope, failureMapping: { _ in .invalidScope }
    )
}

@Test func RUN013_reboundDetachedTaskUsesEntireChainAndRestoresContext() async throws {
    let session = MockSession()
    let scope = session.makeMock()
    let endpoint = reboundEndpoint(scope: scope)
    let sibling = reboundEndpoint(scope: scope)
    let outer = reboundPlan { stubs in
        stubs.matching(.equal(1)).willReturn("outer-shared")
        stubs.matching(.equal(2)).willReturn("outer-only")
    }
    let inner = reboundPlan { $0.matching(.equal(1)).willReturn("inner-shared") }

    #expect(try endpoint.currentScopedConfiguration() == nil)
    try await endpoint.withScopedConfiguration(outer) {
        let outerHandle = try #require(try endpoint.currentScopedConfiguration())
        try await endpoint.withScopedConfiguration(inner) {
            let innerHandle = try #require(try endpoint.currentScopedConfiguration())
            #expect(innerHandle.sessionID == session.id)
            #expect(innerHandle.epoch == session.snapshot().epoch)
            #expect(innerHandle.endpoint == EndpointID("rebind.fetch"))
            let detached = try await Task.detached {
                #expect(try endpoint.currentScopedConfiguration() == nil)
                let before = try await endpoint.invoke(1)
                let rebound = try await endpoint.withScopedConfiguration(innerHandle) {
                    let first = try await endpoint.invoke(1)
                    let second = try await endpoint.invoke(2)
                    let third = try await endpoint.invoke(3)
                    return [first, second, third]
                }
                let after = try await endpoint.invoke(1)
                #expect(try endpoint.currentScopedConfiguration() == nil)
                return [before] + rebound + [after]
            }.value
            #expect(detached == ["base", "inner-shared", "outer-only", "base", "base"])

            let siblingPlan = reboundPlan { $0.matching(.any).willReturn("sibling") }
            try await sibling.withScopedConfiguration(siblingPlan) {
                let redirected = try await endpoint.withScopedConfiguration(outerHandle) {
                    let original = try await endpoint.invoke(1)
                    let other = try await sibling.invoke(1)
                    return [original, other]
                }
                #expect(redirected == ["outer-shared", "sibling"])
                let restored = try await endpoint.invoke(1)
                #expect(restored == "inner-shared")
            }
        }
    }
    #expect(try endpoint.currentScopedConfiguration() == nil)
}

@Test func RUN013_explicitHandleRefusesOtherSessionsAndEndpointInstances() async throws {
    let session = MockSession()
    let scope = session.makeMock()
    let endpoint = reboundEndpoint(scope: scope)
    let sibling = reboundEndpoint(scope: scope)
    let foreign = MockSession()
    let stranger = reboundEndpoint(scope: foreign.makeMock())
    let overlay = reboundPlan { $0.matching(.any).willReturn("scoped") }
    try await endpoint.withScopedConfiguration(overlay) {
        let handle = try #require(try endpoint.currentScopedConfiguration())
        await #expect(throws: ScopedConfigurationBindingError.foreignEndpoint) {
            try await sibling.withScopedConfiguration(handle) { Issue.record("Entered a foreign endpoint scope") }
        }
        await #expect(throws: ScopedConfigurationBindingError.foreignSession(expected: foreign.id, actual: session.id)) {
            try await stranger.withScopedConfiguration(handle) { Issue.record("Entered a foreign session scope") }
        }
    }
    #expect(session.snapshot().events.isEmpty)
    #expect(foreign.snapshot().events.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func RUN013_rebindDoesNotExtendOriginatingScopeLifetime() async throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let endpoint = reboundEndpoint(
        scope: session.makeMock(), reporter: FailureReporter { issues.set(issues.get() + [$0]) }
    )
    let overlay = reboundPlan { $0.matching(.any).willReturn("scoped") }
    let entered = AsyncStream<String>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    defer { resume.continuation.finish() }

    let (handle, held) = try await endpoint.withScopedConfiguration(overlay) {
        let handle = try #require(try endpoint.currentScopedConfiguration())
        let worker = Task.detached {
            defer { entered.continuation.finish() }
            return try await endpoint.withScopedConfiguration(handle) {
                let initial = try await endpoint.invoke(1)
                entered.continuation.yield(initial)
                for await _ in resume.stream { break }
                return try await endpoint.invoke(2)
            }
        }
        var initial = entered.stream.makeAsyncIterator()
        let first = await initial.next()
        #expect(first == "scoped")
        return (handle, worker)
    }
    resume.continuation.finish()
    await #expect(throws: RebindRuleFailure.invalidScope) { try await held.value }
    await #expect(throws: ScopedConfigurationError.closedScope) {
        try await endpoint.withScopedConfiguration(handle) { Issue.record("Entered a closed scope") }
    }
    #expect(issues.get().count == 1)
    #expect(issues.get().first?.message.contains("closed scoped configuration") == true)
    #expect(endpoint.invocations.map(\.input) == [1])
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned])
}

@Test func RUN013_explicitHandlesValidateEpochAndSessionFinish() async throws {
    let session = MockSession()
    let endpoint = reboundEndpoint(scope: session.makeMock())
    let overlay = reboundPlan { $0.matching(.any).willReturn("scoped") }

    try await endpoint.withScopedConfiguration(overlay) {
        let previous = try #require(try endpoint.currentScopedConfiguration())
        let current = try session.resetHistory()
        #expect(previous.epoch != current)
        #expect(throws: ScopedConfigurationError.staleScope) { try endpoint.currentScopedConfiguration() }
        await #expect(throws: ScopedConfigurationError.staleScope) {
            try await endpoint.withScopedConfiguration(previous) { Issue.record("Entered a stale epoch") }
        }
    }
    try await endpoint.withScopedConfiguration(overlay) {
        let finishing = try #require(try endpoint.currentScopedConfiguration())
        let finished = try session.finishIfQuiescent()
        #expect(finished.isFinished)
        #expect(throws: ScopedConfigurationError.finishedSession) { try endpoint.currentScopedConfiguration() }
        await #expect(throws: ScopedConfigurationError.finishedSession) {
            try await endpoint.withScopedConfiguration(finishing) { Issue.record("Entered a finished session") }
        }
        #expect(session.snapshot() == finished)
    }
}


private final class ReboundPlanPayload: Sendable {
    let released: StoredProperty<Bool>
    let session: MockSession

    init(released: StoredProperty<Bool>, session: MockSession) {
        self.released = released
        self.session = session
    }

    deinit {
        _ = session.snapshot()
        released.set(true)
    }
}

@Test func RUN013_transportHandleRetainsNoPlanPayload() async throws {
    let session = MockSession()
    let endpoint = reboundEndpoint(scope: session.makeMock())
    let released = StoredProperty(false)

    func capturingPlan() async throws -> ScopedConfigurationHandle {
        let payload = ReboundPlanPayload(released: released, session: session)
        let overlay = reboundPlan { stubs in
            stubs.matching(.any).willAnswer { _ in withExtendedLifetime(payload) { "scoped" } }
        }
        return try await endpoint.withScopedConfiguration(overlay) {
            return try #require(try endpoint.currentScopedConfiguration())
        }
    }

    let handle = try await capturingPlan()
    #expect(released.get())
    await #expect(throws: ScopedConfigurationError.closedScope) {
        try await endpoint.withScopedConfiguration(handle) { Issue.record("Rebound a retired plan") }
    }
    #expect(session.snapshot().events.isEmpty)
}
