import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

@Test func RUN036_generatedMocksShareOnlyTheirExplicitSession() async throws {
    let session = MockSession()
    let first = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willReturn("first")
    }
    let second = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willReturn("second")
    }
    let independent = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.greeting(for: .any).willReturn("independent")
    }
    #expect(first.greeting(for: "first call") == "first")
    #expect(second.greeting(for: "second call") == "second")
    let detachedAnswer = await Task.detached { independent.greeting(for: "detached call") }.value
    #expect(detachedAnswer == "independent")

    let events = session.snapshot().events
    try #require(events.count == 4)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events[0].mockID == events[1].mockID)
    #expect(events[2].mockID == events[3].mockID)
    #expect(events[0].mockID != events[2].mockID)
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
    #expect(events.allSatisfy { $0.endpoint == events[0].endpoint })
    #expect(zip(events, events.dropFirst()).allSatisfy { pair in pair.0.ordinal < pair.1.ordinal })
    #expect(first.verify.greeting(for: .equal("first call")).wasCalled(.once).passed)
    #expect(first.verify.greeting(for: .equal("second call")).wasCalled(.never).passed)
    #expect(second.verify.greeting(for: .equal("second call")).wasCalled(.once).passed)
}
