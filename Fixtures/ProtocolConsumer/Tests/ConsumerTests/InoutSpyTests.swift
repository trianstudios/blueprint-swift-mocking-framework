import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private struct RealInoutSpyDirectory: InoutSpyDirectory {
    func adjust(_ value: inout Int) throws(InoutSpyFailure) -> Int {
        value += 10
        if value == 9 { throw .afterMutation }
        return value * 2
    }

    func normalize(_ value: inout Int) {
        value = max(0, value)
    }
}

@Test func GEN019_RUN018_syncTypedInoutSpyPreservesMutationsAndExactErrors() throws {
    let session = MockSession()
    let mock = InoutSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: RealInoutSpyDirectory()
    ) { stubs in
        stubs.adjust(.equal(7)).willAnswer { (value: inout Int) throws(InoutSpyFailure) in
            value *= 3
            return value + 100
        }
        stubs.adjust(.equal(8)).willAnswer { (value: inout Int) throws(InoutSpyFailure) in
            value = 88
            throw .stubbed
        }
    }
    let client = InoutSpyClient(directory: mock)

    var forwardedReturn = 2
    #expect(try client.adjust(&forwardedReturn) == 24)
    #expect(forwardedReturn == 12)

    var forwardedThrow = -1
    #expect(throws: InoutSpyFailure.afterMutation) { try client.adjust(&forwardedThrow) }
    #expect(forwardedThrow == 9)

    var stubbedReturn = 7
    #expect(try client.adjust(&stubbedReturn) == 121)
    #expect(stubbedReturn == 21)

    var stubbedThrow = 8
    #expect(throws: InoutSpyFailure.stubbed) { try client.adjust(&stubbedThrow) }
    #expect(stubbedThrow == 88)

    #expect(mock.verify.adjust(.equal(2), after: .equal(12), phase: .returned,
                               origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.adjust(.equal(-1), after: .equal(9), phase: .threw,
                               origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.adjust(.equal(7), after: .equal(21), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.adjust(.equal(8), after: .equal(88), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.adjust(.equal(9), phase: .threw).wasCalled(.never).passed)
    #expect(mock.verify.adjust(.equal(-1), after: .equal(8), phase: .threw).wasCalled(.never).passed)

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase != .admitted }
    #expect(snapshot.events.count == 8)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(admissions.allSatisfy { $0.origin == nil })
    #expect(admissions.map(\.invocationID) == outcomes.map(\.invocationID))
    #expect(Set(admissions.map(\.invocationID)).count == 4)
    #expect(outcomes.map(\.phase) == [.returned, .threw, .returned, .threw])
    #expect(outcomes.map { $0.origin == .forwarded } == [true, true, false, false])
}

@Test func GEN019_RUN018_syncInoutSpyWithVoidResultHonorsExplicitStub() {
    let session = MockSession()
    let mock = InoutSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: RealInoutSpyDirectory()
    ) { stubs in
        stubs.normalize(.equal(-4)).willAnswer { (value: inout Int) in
            value = -40
        }
    }
    let client = InoutSpyClient(directory: mock)

    var forwarded = -2
    var stubbed = -4
    client.normalize(&forwarded)
    client.normalize(&stubbed)
    #expect(forwarded == 0)
    #expect(stubbed == -40)

    #expect(mock.verify.normalize(.equal(-2), after: .equal(0), phase: .returned,
                                  origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.normalize(.equal(-4), after: .equal(-40), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.normalize(.equal(-4), phase: .returned, origin: .forwarded).wasCalled(.never).passed)

    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.filter { $0.origin == .forwarded }.count == 1)
}
