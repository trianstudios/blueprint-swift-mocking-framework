import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func RUN018_generatedSpyUsesRealTypedEffectsWithoutInterceptingRealSelfCalls() async throws {
    let session = MockSession()
    let real = RealSpyDirectory()
    let mock = SpyDirectoryMock(failureReporter: .swiftTesting, session: session, forwardingTo: real) { stubs in
        stubs.display(for: .equal("shared")).willReturn("stub:shared")
        stubs.fetch(id: .equal("explicit")).willReturn("stub:remote")
    }
    let client = SpyDirectoryClient(directory: mock)

    #expect(client.display(for: "direct") == "real:direct")
    #expect(client.display(for: "shared") == "stub:shared")
    #expect(try client.cached(id: "shared") == "cache:real:shared")
    #expect(throws: SpyDirectoryFailure.offline) { try client.cached(id: "cached-offline") }
    #expect(try await client.fetch(id: "shared") == "fetch:real:shared")
    await #expect(throws: SpyDirectoryFailure.offline) { try await client.fetch(id: "remote-offline") }
    #expect(try await client.fetch(id: "explicit") == "stub:remote")
    #expect(await real.observedRemoteIDs() == ["shared", "remote-offline"])

    #expect(mock.verify.display(for: .any).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.display(for: .equal("shared")).wasCalled(.once).passed)
    #expect(mock.verify.display(for: .equal("shared"), phase: .returned, origin: .forwarded).wasCalled(.never).passed)
    #expect(mock.verify.display(for: .equal("direct"), phase: .returned, origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.cached(id: .equal("cached-offline"), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.fetch(id: .equal("remote-offline"), phase: .threw, origin: .forwarded).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase != .admitted }
    #expect(snapshot.events.count == 14)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(Set(admissions.map(\.invocationID)).count == 7)
    #expect(admissions.map(\.invocationID) == outcomes.map(\.invocationID))
    #expect(admissions.allSatisfy { $0.origin == nil })
    #expect(outcomes.map(\.phase) == [.returned, .returned, .returned, .threw, .returned, .threw, .returned])
    #expect(outcomes.map { $0.origin == .forwarded } == [true, false, true, true, true, true, false])
}

@Test func RUN018_exhaustedWinningSequenceDoesNotFallThroughToTheInjectedReal() async throws {
    let session = MockSession()
    let real = RealSpyDirectory()
    let mock = SpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: real,
        failureMappings: .init { mappings in
            mappings.fetch(id: String.self) { issue in
                #expect(issue.kind == .sequenceExhausted)
                return .exhausted
            }
        }
    ) { stubs in
        stubs.fetch(id: .equal("burst")).willSequence(.returning("scripted"))
    }
    let client = SpyDirectoryClient(directory: mock)

    #expect(try await client.fetch(id: "burst") == "scripted")
    await withKnownIssue("An exhausted winning sequence reports before its typed error mapping") {
        await #expect(throws: SpyDirectoryFailure.exhausted) { try await client.fetch(id: "burst") }
    }
    #expect(await real.observedRemoteIDs().isEmpty)
    #expect(try await client.fetch(id: "other") == "fetch:real:other")
    #expect(await real.observedRemoteIDs() == ["other"])
    #expect(mock.verify.fetch(id: .equal("burst"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetch(id: .equal("burst"), phase: .threw).wasCalled(.once).passed)

    let events = session.snapshot().events
    #expect(events.count == 6)
    let admissions = events.filter { $0.phase == .admitted }
    let outcomes = events.filter { $0.phase != .admitted }
    #expect(admissions.map(\.invocationID) == outcomes.map(\.invocationID))
    #expect(outcomes.map(\.phase) == [.returned, .threw, .returned])
    #expect(outcomes.map { $0.origin == .forwarded } == [false, false, true])
}

@Test func RUN018_generatedSpyForwardsReadOnlyAccessorsAndAsyncValues() async {
    let session = MockSession()
    let real = RealSpyDirectory()
    let mock = SpyDirectoryMock(failureReporter: .swiftTesting, session: session, forwardingTo: real) { _ in }
    let client = SpyDirectoryClient(directory: mock)

    #expect(client.inspect(3, region: "north") == "real:north:3")
    #expect(await client.refresh("delta") == "refresh:delta")
    #expect(await real.observedRemoteIDs() == ["delta"])

    #expect(mock.verify.get_displayPrefix(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal(3), region: .equal("north"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.refresh(.equal("delta"), phase: .returned).wasCalled(.once).passed)
    let events = session.snapshot().events
    #expect(events.count == 6)
    #expect(events.filter { $0.origin == .forwarded }.map(\.phase) == [.returned, .returned, .returned])
}
