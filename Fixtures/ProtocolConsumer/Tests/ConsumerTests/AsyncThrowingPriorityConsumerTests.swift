import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func RUN013_generatedAsyncRulePriorityComposesWithWinningCaptures() async throws {
    let session = MockSession()
    let selected = ArgumentCaptor<String>(session: session)
    let losing = ArgumentCaptor<String>(session: session)
    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.fetchUser(id: .equal("one")).priority(9)
            .capturing(into: selected, projecting: { "first-\($0)" })
            .willReturn("one")
        stubs.fetchUser(id: .equal("two"))
            .capturing(into: selected, projecting: { "second-\($0)" })
            .priority(9)
            .willAnswer { id async throws(RepositoryError) in id }
        stubs.fetchUser(id: .any)
            .capturing(into: losing, projecting: { $0 })
            .willThrow(.offline)
    }
    let service = UserService(repository: mock)

    #expect(try await service.load(id: "one") == "one")
    #expect(try await service.load(id: "two") == "two")
    #expect(mock.verify.fetchUser(id: .any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(selected.captures.map(\.value) == ["first-one", "second-two"])
    #expect(losing.captures.isEmpty)
    #expect(selected.captures.map(\.invocation) == session.snapshot().events.filter { $0.phase == .admitted })
}
