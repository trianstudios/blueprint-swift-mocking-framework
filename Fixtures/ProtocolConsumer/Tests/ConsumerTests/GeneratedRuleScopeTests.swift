import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func RUN013_generatedScopedRulesFollowProtocolCallsAndUnwind() async throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let mock = ScopedUserDirectoryMock(
        failureReporter: FailureReporter { issues.set(issues.get() + [$0]) },
        session: session,
        failureMappings: .init { mappings in
            mappings.fetch(id: String.self) { _ in .exhausted }
        }
    ) { stubs in
        stubs.fetch(id: .any).willAnswer { "base/\($0)" }
        stubs.label(for: .any).willAnswer { "label/\($0)" }
    }
    let directory: any ScopedUserDirectory = mock

    let initialBase = try await directory.fetch(id: "shared")
    #expect(initialBase == "base/shared")
    try await mock.ruleScopes.fetch(
        id: String.self,
        configure: { stubs in
            stubs.matching(.equal("shared")).willReturn("outer/shared")
            stubs.matching(.equal("outer-only")).willReturn("outer/outer-only")
        },
        operation: {
            let outerBeforeInner = try await directory.fetch(id: "shared")
            #expect(outerBeforeInner == "outer/shared")
            try await mock.ruleScopes.fetch(
                id: String.self,
                configure: { stubs in
                    stubs.matching(.equal("shared")).willSequence(.returning("inner/shared"), policy: .finite)
                },
                operation: {
                    let innerWinner = try await directory.fetch(id: "shared")
                    #expect(innerWinner == "inner/shared")
                    await #expect(throws: ScopedDirectoryError.exhausted) {
                        try await directory.fetch(id: "shared")
                    }
                    let outerMiss = try await directory.fetch(id: "outer-only")
                    #expect(outerMiss == "outer/outer-only")
                    let baseMiss = try await directory.fetch(id: "base-only")
                    #expect(baseMiss == "base/base-only")
                    #expect(directory.label(for: "shared") == "label/shared")
                }
            )
            let restoredOuter = try await directory.fetch(id: "shared")
            #expect(restoredOuter == "outer/shared")
        }
    )
    let restoredBase = try await directory.fetch(id: "shared")
    #expect(restoredBase == "base/shared")
    #expect(issues.get().map(\.kind) == [.sequenceExhausted])

    #expect(mock.verify.fetch(id: .equal("shared"), phase: .returned).wasCalled(.exactly(5)).passed)
    #expect(mock.verify.fetch(id: .equal("shared"), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.fetch(id: .equal("outer-only"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetch(id: .equal("base-only"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.label(for: .equal("shared"), phase: .returned).wasCalled(.once).passed)

    let history = session.snapshot()
    let admissions = history.events.filter { $0.phase == .admitted }
    let outcomes = history.events.filter { $0.phase != .admitted }
    #expect(history.activeInvocationCount == 0)
    #expect(admissions.count == 9)
    #expect(admissions.map(\.invocationID) == outcomes.map(\.invocationID))
    #expect(admissions.map(\.endpoint) == outcomes.map(\.endpoint))
    #expect(outcomes.filter { $0.phase == .threw }.map(\.endpoint) == issues.get().map(\.endpoint))
}

private final class ActorLocalRuleScopePayload {
    let label = "local"
}

@Test @MainActor func RUN013_generatedScopePreservesTheCallersActor() async throws {
    let payload = ActorLocalRuleScopePayload()
    let mock = ScopedUserDirectoryMock(failureReporter: FailureReporter { Issue.record(Comment(rawValue: $0.message)) }) {
        $0.fetch(id: .any).willReturn("base")
    }
    let directory: any ScopedUserDirectory = mock
    let returned = try await mock.ruleScopes.fetch(
        id: String.self,
        configure: { $0.matching(.equal(payload.label)).willReturn("scoped") },
        operation: {
            MainActor.preconditionIsolated()
            let result = try await directory.fetch(id: payload.label)
            #expect(result == "scoped")
            return payload
        }
    )
    #expect(returned === payload)
}
