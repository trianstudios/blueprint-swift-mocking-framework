import BlueprintMocking
import Testing

private enum PriorityFailure: Error {
    case exhausted
}

private typealias PriorityEndpoint = AsyncThrowingEndpoint<Int, String, PriorityFailure>
private typealias PriorityStubs = AsyncThrowingStubbing<Int, String, PriorityFailure>

private func priorityPlan(_ configure: (PriorityStubs) -> Void)
    -> AsyncThrowingConfiguration<Int, String, PriorityFailure> {
    let stubs = PriorityStubs()
    configure(stubs)
    return stubs.finish()
}

@Test func RUN013_asyncRulePriorityBeatsRegistrationAndUsesLatestForTies() async throws {
    let endpoint = PriorityEndpoint(
        id: EndpointID("priority.order"),
        configuration: priorityPlan { stubs in
            stubs.matching(.equal(1)).priority(Int.max).willReturn("earlier-high")
            stubs.matching(.equal(1)).willReturn("later-default")
            stubs.matching(.equal(2)).priority(4).willReturn("earlier-tie")
            stubs.matching(.equal(2)).priority(4).willReturn("later-tie")
            stubs.matching(.equal(3)).willReturn("default wins")
            stubs.matching(.equal(3)).priority(Int.min).willReturn("later-low")
            stubs.matching(.equal(4)).willReturn("earlier-default")
            stubs.matching(.equal(4)).willReturn("later-default")
            stubs.matching(.equal(5)).priority(1).willThrow(.exhausted)
            stubs.matching(.equal(5)).willReturn("must not return")
        },
        failureReporter: FailureReporter { Issue.record("\($0.message)") }
    )

    #expect(try await endpoint.invoke(1) == "earlier-high")
    #expect(try await endpoint.invoke(2) == "later-tie")
    #expect(try await endpoint.invoke(3) == "default wins")
    #expect(try await endpoint.invoke(4) == "later-default")
    await #expect(throws: PriorityFailure.exhausted) { try await endpoint.invoke(5) }
    #expect(endpoint.invocations.map(\.phase) == [.returned, .returned, .returned, .returned, .threw])
}

@Test func RUN013_asyncScopeLayerWinsBeforeRulePriorityAndExhaustion() async throws {
    let issues = StoredProperty<[MockIssue]>([])
    let forwarded = StoredProperty<[Int]>([])
    let endpoint = PriorityEndpoint(
        id: EndpointID("priority.scopes"),
        configuration: priorityPlan { $0.matching(.equal(1)).priority(Int.max).willReturn("base") },
        failureReporter: FailureReporter { issues.set(issues.get() + [$0]) },
        forwarding: AsyncThrowingForwarding { input in
            forwarded.set(forwarded.get() + [input])
            return "forwarded"
        },
        failureMapping: { _ in .exhausted }
    )
    let outer = priorityPlan { $0.matching(.equal(1)).priority(100).willReturn("outer") }
    let inner = priorityPlan { stubs in
        stubs.matching(.equal(1)).priority(-100).willSequence(.returning("inner"))
        stubs.matching(.equal(1)).priority(Int.min).willReturn("low inner")
    }

    try await endpoint.withScopedConfiguration(outer) {
        let outerResult = try await endpoint.invoke(1)
        #expect(outerResult == "outer")
        try await endpoint.withScopedConfiguration(inner) {
            let innerResult = try await endpoint.invoke(1)
            #expect(innerResult == "inner")
            await #expect(throws: PriorityFailure.exhausted) { try await endpoint.invoke(1) }
            #expect(forwarded.get().isEmpty)
        }
        let restored = try await endpoint.invoke(1)
        #expect(restored == "outer")
    }
    #expect(try await endpoint.invoke(1) == "base")
    #expect(try await endpoint.invoke(2) == "forwarded")
    #expect(issues.get().map(\.kind) == [.sequenceExhausted])
    #expect(forwarded.get() == [2])
    #expect(endpoint.invocations.map(\.phase) == [.returned, .returned, .threw, .returned, .returned, .returned])
}
