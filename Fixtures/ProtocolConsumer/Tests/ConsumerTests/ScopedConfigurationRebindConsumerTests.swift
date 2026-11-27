import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct ExplicitlyBoundRepository: UserRepository {
    let fetch: AsyncThrowingEndpoint<String, String, RepositoryError>

    func greeting(for name: String) -> String { name }
    func greeting(_ name: String) -> String { name }

    func fetchUser(id: String) async throws(RepositoryError) -> String {
        try await fetch.invoke(id)
    }
}

@Test func RUN013_consumerRebindsDetachedServiceCallsAndRejectsStaleHandle() async throws {
    let session = MockSession()
    let reporter = FailureReporter { Issue.record("\($0.message)") }
    let base = AsyncThrowingStubbing<String, String, RepositoryError>()
    base.matching(.any).willAnswer { "base/\($0)" }
    let fetch = AsyncThrowingEndpoint(
        id: EndpointID("consumer.rebound.fetchUser"), configuration: base.finish(),
        failureReporter: reporter, scope: session.makeMock(), failureMapping: { _ in .offline }
    )
    let service = UserService(repository: ExplicitlyBoundRepository(fetch: fetch))
    let generated = UserRepositoryMock(failureReporter: reporter, session: session) { stubs in
        stubs.fetchUser(id: .any).willAnswer { "generated/\($0)" }
    }
    let independent = UserService(repository: generated)
    let overlay = AsyncThrowingStubbing<String, String, RepositoryError>()
    overlay.matching(.equal("42")).willReturn("scoped/42")

    try await fetch.withScopedConfiguration(overlay.finish()) {
        let handle = try #require(try fetch.currentScopedConfiguration())
        let outcomes = try await Task.detached {
            let unbound = try await service.load(id: "42")
            let rebound = try await fetch.withScopedConfiguration(handle) {
                let selected = try await service.load(id: "42")
                let missed = try await service.load(id: "other")
                let unrelated = try await independent.load(id: "42")
                return [selected, missed, unrelated]
            }
            let restored = try await service.load(id: "42")
            return [unbound] + rebound + [restored]
        }.value
        #expect(outcomes == ["base/42", "scoped/42", "base/other", "generated/42", "base/42"])
        #expect(generated.verify.fetchUser(id: .equal("42"), phase: .returned).wasCalled(.once).passed)

        let newEpoch = try session.resetHistory()
        #expect(handle.epoch != newEpoch)
        let reset = session.snapshot()
        await #expect(throws: ScopedConfigurationError.staleScope) {
            try await Task.detached {
                try await fetch.withScopedConfiguration(handle) {
                    Issue.record("Entered a scope from an earlier session epoch")
                    return try await service.load(id: "42")
                }
            }.value
        }
        #expect(session.snapshot() == reset)
    }

    let afterScope = try await service.load(id: "42")
    #expect(afterScope == "base/42")
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned])
}
