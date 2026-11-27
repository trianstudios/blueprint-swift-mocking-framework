import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN012_returnOnlyOverloadsUseSeparateTypedEndpoints() throws {
    let session = MockSession()
    let id = "shared"
    let mock = ResultOverloadDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.lookup(id: .equal(id), returning: Int.self).willReturn(42)
        stubs.lookup(id: .equal(id), returning: String.self).willAnswer { "name for \($0)" }
    }
    let client = ResultOverloadClient(directory: mock)
    let counts = mock.verify.lookup(id: .equal(id), returning: Int.self, phase: .returned)
    let names = mock.verify.lookup(id: .equal(id), returning: String.self, phase: .returned)

    #expect(client.loadCount(id: id) == 42)
    #expect(counts.wasCalled(.once).passed)
    #expect(names.wasCalled(.never).passed)

    #expect(client.loadName(id: id) == "name for shared")
    #expect(counts.wasCalled(.once).passed)
    #expect(names.wasCalled(.once).passed)

    let history = session.snapshot()
    #expect(history.activeInvocationCount == 0)
    #expect(history.events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    let admissions = history.events.filter { $0.phase == .admitted }
    let returns = history.events.filter { $0.phase == .returned }
    try #require(admissions.count == 2)
    #expect(admissions[0].endpoint != admissions[1].endpoint)
    #expect(admissions[0].invocationID != admissions[1].invocationID)
    #expect(admissions.map(\.endpoint) == returns.map(\.endpoint))
    #expect(admissions.map(\.invocationID) == returns.map(\.invocationID))
}
