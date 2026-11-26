import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN024_generatedSubscriptsRouteTypedSelectorsAndRecordReadModifyWrite() throws {
    let session = MockSession()
    let mock = SubscriptDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(.equal(7)).willReturn("integer")
        stubs.get_subscript(.equal("7")).willReturn("string")
        stubs.get_subscript(.equal(7), .equal(2)).willReturn("grid")
        stubs.get_subscript(.equal(7), column: .equal("status")).willReturn("draft")
        stubs.set_subscript(.equal(7), column: .equal("status"), newValue: .equal("draft!")).willReturn(())
    }
    var directory: any SubscriptDirectory = mock

    #expect(directory[7] == "integer")
    #expect(directory["7"] == "string")
    #expect(directory[7, 2] == "grid")
    #expect(mock.verify.get_subscript(.equal(7), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal("7"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal(7), .equal(2), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal(7), column: .equal("status")).wasCalled(.never).passed)
    #expect(mock.verify.set_subscript(.equal(7), column: .equal("status"), newValue: .any).wasCalled(.never).passed)

    let checkpoint = session.checkpoint()
    directory[7, column: "status"] += "!"

    #expect(mock.verify.get_subscript(.equal(7), column: .equal("status"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(.equal(7), column: .equal("status"), newValue: .equal("draft!"),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(.equal(7), column: .equal("status"),
                                     newValue: .equal("draft")).wasCalled(.never).passed)

    let events = try session.events(since: checkpoint)
    try #require(events.count == 4)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events[0].mockID == events[2].mockID)
    #expect(events[0].endpoint != events[2].endpoint)
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
}

@Test func GEN024_subscriptSettersUseTheWitnessLocalsForZeroAndOneIndex() {
    let mock = SubscriptDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.get_subscript().willReturn(6)
        stubs.set_subscript(newValue: .equal(10)).willReturn(())
        stubs.get_subscript(slot: .equal(true)).willReturn(20)
        stubs.set_subscript(slot: .equal(true), newValue: .equal(21)).willReturn(())
    }
    var directory: any SubscriptDirectory = mock

    directory[] += 4
    directory[slot: true] += 1

    #expect(mock.verify.get_subscript().wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(newValue: .equal(10)).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(slot: .equal(true)).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(slot: .equal(true), newValue: .equal(21)).wasCalled(.once).passed)
}
