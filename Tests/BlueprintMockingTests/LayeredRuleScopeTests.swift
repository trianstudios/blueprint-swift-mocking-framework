import Testing
@testable import BlueprintMocking

private enum ScopedFixtureError: Error, Sendable {
    case failed
    case exhausted
    case invalidScope
}

private final class ScopedIssues: Sendable {
    private let storage = CriticalState<[MockIssue]>([])
    var values: [MockIssue] { storage.withLock { $0 } }
    var reporter: FailureReporter {
        FailureReporter { [self] issue in storage.withLock { $0.append(issue) } }
    }
}

private typealias ScopedEndpoint = AsyncThrowingEndpoint<Int, String, ScopedFixtureError>
private typealias ScopedStubbing = AsyncThrowingStubbing<Int, String, ScopedFixtureError>

private func configured(_ fill: (ScopedStubbing) -> Void)
    -> AsyncThrowingConfiguration<Int, String, ScopedFixtureError> {
    let stubbing = ScopedStubbing()
    fill(stubbing)
    return stubbing.finish()
}

@Test func RUN013_nestedScopesRestoreAndConsultOuterRulesOnMiss() async throws {
    let endpoint = ScopedEndpoint(
        id: EndpointID("layered.nesting"),
        configuration: configured {
            $0.matching(.any).willReturn("base")
        },
        failureReporter: FailureReporter { Issue.record("\($0.message)") }
    )
    let outer = configured {
        $0.matching(.equal(1)).willReturn("outer")
        $0.matching(.equal(2)).willReturn("outer two")
    }
    let inner = configured {
        $0.matching(.equal(1)).willReturn("inner")
    }

    let result1 = try await endpoint.invoke(1)
    #expect(result1 == "base")
    try await endpoint.withScopedConfiguration(outer) {
        let result2 = try await endpoint.invoke(1)
        #expect(result2 == "outer")
        try await endpoint.withScopedConfiguration(inner) {
            let result3 = try await endpoint.invoke(1)
            #expect(result3 == "inner")
            let result4 = try await endpoint.invoke(2)
            #expect(result4 == "outer two")
            let result5 = try await endpoint.invoke(3)
            #expect(result5 == "base")
        }
        let result6 = try await endpoint.invoke(1)
        #expect(result6 == "outer")
    }
    let result7 = try await endpoint.invoke(1)
    #expect(result7 == "base")
    #expect(endpoint.invocations.map(\.phase) == Array(repeating: .returned, count: 7))
}

@Test func RUN013_anExhaustedInnerWinnerBlocksOuterBaseAndForwarding() async throws {
    let issues = ScopedIssues()
    let forwarded = CriticalState<[Int]>([])
    let endpoint = ScopedEndpoint(
        id: EndpointID("layered.exhaustion"),
        configuration: configured { $0.matching(.equal(1)).willReturn("base") },
        failureReporter: issues.reporter,
        forwarding: AsyncThrowingForwarding { input in
            forwarded.withLock { $0.append(input) }
            return "forward"
        },
        failureMapping: { _ in .exhausted }
    )
    let outer = configured { $0.matching(.any).willReturn("outer") }
    let inner = configured { $0.matching(.any).willSequence(.returning("first")) }

    try await endpoint.withScopedConfiguration(outer) {
        try await endpoint.withScopedConfiguration(inner) {
            let result8 = try await endpoint.invoke(1)
            #expect(result8 == "first")
            do {
                _ = try await endpoint.invoke(1)
                Issue.record("The exhausted scope fell through to a lower rule")
            } catch {
                #expect(error as? ScopedFixtureError == .exhausted)
            }
            do {
                _ = try await endpoint.invoke(2)
                Issue.record("The exhausted scope fell through to forwarding")
            } catch {
                #expect(error as? ScopedFixtureError == .exhausted)
            }
        }
        let result9 = try await endpoint.invoke(1)
        #expect(result9 == "outer")
    }
    let result10 = try await endpoint.invoke(1)
    #expect(result10 == "base")
    let result11 = try await endpoint.invoke(2)
    #expect(result11 == "forward")
    #expect(issues.values.map(\.kind) == [.sequenceExhausted, .sequenceExhausted])
    #expect(forwarded.withLock { $0 } == [2])
    #expect(endpoint.invocations.map(\.phase) == [.returned, .threw, .threw, .returned, .returned, .returned])
    #expect(endpoint.invocations.filter { $0.origin == .forwarded }.map(\.input) == [2])
}

@Test func RUN013_lexicalScopesAreBoundToTheEndpointInstanceAndTaskContext() async throws {
    let session = MockSession()
    let base = configured { $0.matching(.any).willReturn("base") }
    let scope = configured { $0.matching(.any).willReturn("scoped") }
    let report = FailureReporter { Issue.record("\($0.message)") }
    let endpoint = ScopedEndpoint(id: EndpointID("same"), configuration: base, failureReporter: report,
                                  scope: session.makeMock())
    let sibling = ScopedEndpoint(id: EndpointID("same"), configuration: base, failureReporter: report,
                                 scope: session.makeMock())
    let otherSession = ScopedEndpoint(id: EndpointID("same"), configuration: base, failureReporter: report)

    try await endpoint.withScopedConfiguration(scope) {
        let result12 = try await Task { try await endpoint.invoke(1) }.value
        #expect(result12 == "scoped")
        let result13 = try await Task.detached { try await endpoint.invoke(1) }.value
        #expect(result13 == "base")
        let result14 = try await sibling.invoke(1)
        #expect(result14 == "base")
        let result15 = try await otherSession.invoke(1)
        #expect(result15 == "base")
    }
}

@Test func RUN013_scopeRestoresAfterErrorAndTaskCancellation() async throws {
    let endpoint = ScopedEndpoint(
        id: EndpointID("layered.unwind"),
        configuration: configured { $0.matching(.any).willReturn("base") },
        failureReporter: FailureReporter { Issue.record("\($0.message)") }
    )
    let scoped = configured { $0.matching(.any).willReturn("scoped") }
    do {
        try await endpoint.withScopedConfiguration(scoped) {
            throw ScopedFixtureError.failed
        }
        Issue.record("Expected the body error")
    } catch {
        #expect(error as? ScopedFixtureError == .failed)
    }
    let result16 = try await endpoint.invoke(1)
    #expect(result16 == "base")

    let restored = try await Task {
        do {
            try await endpoint.withScopedConfiguration(scoped) {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
            Issue.record("Expected the scoped body to throw cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        return try await endpoint.invoke(1)
    }.value
    #expect(restored == "base")
}

@Test func RUN013_closedAndResetScopesRejectWithoutAdmitting() async throws {
    let session = MockSession()
    let issues = ScopedIssues()
    let endpoint = ScopedEndpoint(
        id: EndpointID("layered.lifecycle"),
        configuration: configured { $0.matching(.any).willReturn("base") },
        failureReporter: issues.reporter,
        scope: session.makeMock(),
        failureMapping: { _ in .invalidScope }
    )
    let scoped = configured { $0.matching(.any).willReturn("scope") }
    let signal = AsyncStream<Void>.makeStream()
    let late = try await endpoint.withScopedConfiguration(scoped) {
        Task {
            for await _ in signal.stream { break }
            return try await endpoint.invoke(1)
        }
    }
    signal.continuation.yield()
    signal.continuation.finish()
    do {
        _ = try await late.value
        Issue.record("A task outlived its scope without a diagnosis")
    } catch {
        #expect(error as? ScopedFixtureError == .invalidScope)
    }
    #expect(session.snapshot().events.isEmpty)
    #expect(issues.values.last?.message.contains("closed") == true)

    try await endpoint.withScopedConfiguration(scoped) {
        _ = try session.resetHistory()
        do {
            _ = try await endpoint.invoke(1)
            Issue.record("A scope crossed an epoch boundary")
        } catch {
            #expect(error as? ScopedFixtureError == .invalidScope)
        }
    }
    #expect(session.snapshot().events.isEmpty)
    #expect(issues.values.last?.message.contains("stale") == true)
    let result17 = try await endpoint.invoke(1)
    #expect(result17 == "base")
}
