import BlueprintMocking
import ConsumerDomain
import Testing

private struct LayeredRepositoryAdapter: UserRepository {
    let fetch: AsyncThrowingEndpoint<String, String, RepositoryError>

    func greeting(for name: String) -> String { name }
    func greeting(_ name: String) -> String { name }

    func fetchUser(id: String) async throws(RepositoryError) -> String {
        try await fetch.invoke(id)
    }
}

@Test func RUN013_publicScopedRulesFollowProtocolCallsAndUnwind() async throws {
    let base = AsyncThrowingStubbing<String, String, RepositoryError>()
    base.matching(.any).willAnswer { "base/\($0)" }
    let outer = AsyncThrowingStubbing<String, String, RepositoryError>()
    outer.matching(.equal("shared")).willReturn("outer/shared")
    outer.matching(.equal("outer-only")).willReturn("outer/outer-only")
    let inner = AsyncThrowingStubbing<String, String, RepositoryError>()
    inner.matching(.equal("shared")).willSequence(.returning("inner/shared"), policy: .finite)
    let outerPlan = outer.finish()
    let innerPlan = inner.finish()

    let issues = StoredProperty<[MockIssue]>([])
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("consumer.layered.fetchUser"),
        configuration: base.finish(),
        failureReporter: FailureReporter { issues.set(issues.get() + [$0]) },
        failureMapping: { _ in .offline }
    )
    let service = UserService(repository: LayeredRepositoryAdapter(fetch: endpoint))

    let initial = try await service.load(id: "shared")
    #expect(initial == "base/shared")
    try await endpoint.withScopedConfiguration(outerPlan) {
        let outerShared = try await service.load(id: "shared")
        #expect(outerShared == "outer/shared")
        try await endpoint.withScopedConfiguration(innerPlan) {
            let innerShared = try await service.load(id: "shared")
            #expect(innerShared == "inner/shared")
            await #expect(throws: RepositoryError.offline) {
                try await service.load(id: "shared")
            }
            let outerOnly = try await service.load(id: "outer-only")
            let baseOnly = try await service.load(id: "base-only")
            #expect(outerOnly == "outer/outer-only")
            #expect(baseOnly == "base/base-only")
        }
        let restoredOuter = try await service.load(id: "shared")
        #expect(restoredOuter == "outer/shared")
    }
    let restoredBase = try await service.load(id: "shared")
    #expect(restoredBase == "base/shared")
    #expect(issues.get().map(\.kind) == [.sequenceExhausted])
    #expect(endpoint.invocations.map(\.input) == [
        "shared", "shared", "shared", "shared", "outer-only", "base-only", "shared", "shared",
    ])
    #expect(endpoint.invocations.map(\.phase) == [
        .returned, .returned, .returned, .threw, .returned, .returned, .returned, .returned,
    ])
}
