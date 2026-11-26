import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN024_genericSubscriptKeepsExactSpecializationsAndDeclarationsSeparate() throws {
    let session = MockSession()
    let mock = GenericSubscriptDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(.equal(7), as: Int.self).willReturn(41)
        stubs.get_subscript(.equal("7"), as: String.self).willReturn("text-7")
        stubs.get_subscript(.equal(Optional<Int>.some(7)), as: Optional<Int>.self).willReturn(nil)
        stubs.get_subscript(.equal(Optional<Int>.none), as: Optional<Int>.self).willReturn(9)
        stubs.get_subscript(named: .equal(7), as: Int.self).willReturn("named-7")
    }
    let client = GenericSubscriptClient(directory: mock)

    #expect(client.read(7) == 41)
    #expect(client.read("7") == "text-7")
    #expect(client.read(Optional<Int>.some(7)) == nil)
    #expect(client.name(for: 7) == "named-7")
    #expect(client.read(Optional<Int>.none) == 9)

    #expect(mock.verify.get_subscript(.equal(7), as: Int.self, phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal("7"), as: String.self, phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal(Optional<Int>.some(7)), as: Optional<Int>.self,
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal(Optional<Int>.none), as: Optional<Int>.self,
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(named: .equal(7), as: Int.self, phase: .returned).wasCalled(.once).passed)

    let events = session.snapshot().events
    try #require(events.count == 10)
    let admissions = events.filter { $0.phase == .admitted }
    try #require(admissions.count == 5)
    let optionalName = String(reflecting: Optional<Int>.self)
    #expect(admissions.map { $0.endpoint.specialization?.typeName } == [
        String(reflecting: Int.self), String(reflecting: String.self), optionalName,
        String(reflecting: Int.self), optionalName,
    ])
    #expect(admissions[0].endpoint != admissions[1].endpoint)
    #expect(admissions[0].endpoint != admissions[2].endpoint)
    #expect(admissions[2].endpoint == admissions[4].endpoint)
    #expect(admissions[0].endpoint.rawValue == admissions[1].endpoint.rawValue)
    #expect(admissions[0].endpoint.rawValue == admissions[2].endpoint.rawValue)
    #expect(admissions[0].endpoint.rawValue == admissions[4].endpoint.rawValue)
    #expect(admissions[0].endpoint.rawValue != admissions[3].endpoint.rawValue)
    for index in stride(from: 0, to: events.count, by: 2) {
        #expect(events[index].phase == .admitted)
        #expect(events[index + 1].phase == .returned)
        #expect(events[index].endpoint.specialization == events[index + 1].endpoint.specialization)
        #expect(events[index].invocationID == events[index + 1].invocationID)
    }
}
