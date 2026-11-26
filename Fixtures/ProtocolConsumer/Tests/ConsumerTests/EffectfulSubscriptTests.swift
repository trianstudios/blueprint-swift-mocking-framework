import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN024_generatedEffectfulSubscriptPreservesTypedThrowsAndIndexes() async throws {
    let session = MockSession()
    let mock = EffectfulSubscriptDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(.equal("row"), region: .equal(1)).willReturn("available")
        stubs.get_subscript(.equal("row"), region: .equal(2)).willThrow(.unavailable)
    }
    let directory: any EffectfulSubscriptDirectory = mock

    let available = try await directory["row", region: 1]
    #expect(available == "available")
    do throws(EffectfulSubscriptFailure) {
        _ = try await directory["row", region: 2]
        Issue.record("Expected the generated getter to throw EffectfulSubscriptFailure.unavailable")
    } catch {
        #expect(error == .unavailable)
    }

    #expect(mock.verify.get_subscript(.equal("row"), region: .equal(1), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal("row"), region: .equal(2), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(.equal("row"), region: .equal(3)).wasCalled(.never).passed)

    let events = session.snapshot().events
    try #require(events.count == 4)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .threw])
    #expect(events.allSatisfy { $0.endpoint == events[0].endpoint })
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
}

@Test func GEN024_readOnlySubscriptsPreserveSyncThrowsAsyncAndNever() async throws {
    let session = MockSession()
    let mock = EffectfulSubscriptDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(sync: .equal(-1)).willThrow(.unavailable)
        stubs.get_subscript(asyncValue: .equal(2)).willReturn(20)
        stubs.get_subscript(infallible: .equal("key")).willReturn("always available")
    }
    let directory: any EffectfulSubscriptDirectory = mock

    do throws(EffectfulSubscriptFailure) {
        _ = try directory[sync: -1]
        Issue.record("Expected the synchronous getter to throw its declared error")
    } catch {
        #expect(error == .unavailable)
    }
    let asyncValue = await directory[asyncValue: 2]
    let infallibleValue = directory[infallible: "key"]
    #expect(asyncValue == 20)
    #expect(infallibleValue == "always available")

    #expect(mock.verify.get_subscript(sync: .equal(-1), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(asyncValue: .equal(2), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(infallible: .equal("key"), phase: .returned).wasCalled(.once).passed)

    let events = session.snapshot().events
    try #require(events.count == 6)
    #expect(events.map(\.phase) == [.admitted, .threw, .admitted, .returned, .admitted, .returned])
    #expect(Set(events.filter { $0.phase == .admitted }.map(\.endpoint.rawValue)).count == 3)
}
