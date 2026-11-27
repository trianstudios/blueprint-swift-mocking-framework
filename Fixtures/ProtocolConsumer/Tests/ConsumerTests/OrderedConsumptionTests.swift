import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func RUN027_RUN029_orderedConsumptionHonorsClaimedBarriersAndKeepsHistory() throws {
    let session = MockSession()
    let openingMock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willAnswer { "opening/\($0)" }
        stubs.greeting(.any).willAnswer { "barrier/\($0)" }
    }
    let closingMock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willAnswer { "closing/\($0)" }
    }
    let openingRepository: any UserRepository = openingMock
    let closingRepository: any UserRepository = closingMock

    for round in ["one", "two"] {
        #expect(openingRepository.greeting(for: round) == "opening/\(round)")
        #expect(openingRepository.greeting(round) == "barrier/\(round)")
        #expect(closingRepository.greeting(for: round) == "closing/\(round)")
    }

    let history = session.snapshot()
    let admissions = history.events.filter { $0.phase == .admitted }
    try #require(admissions.count == 6)
    let ids = admissions.map(\.invocationID)
    let opening = SessionCallSelector(mockID: admissions[0].mockID, endpoint: admissions[0].endpoint)
    let barrier = SessionCallSelector(mockID: admissions[1].mockID, endpoint: admissions[1].endpoint)
    let closing = SessionCallSelector(mockID: admissions[2].mockID, endpoint: admissions[2].endpoint)
    #expect(opening.endpoint == closing.endpoint)
    #expect(opening.mockID != closing.mockID)

    let scope = session.consumptionScope(named: "ordered greetings")
    // The prefix exists, but there are only two distinct closing admissions.
    let absent = try session.consumeInOrder([opening, closing, closing, closing], mode: .relative, in: scope)
    #expect(absent == nil)
    let afterMiss = try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope)
    #expect(afterMiss.outcome == .interaction(admissions[0]))

    let claimedBarriers = try session.consume(.all, for: barrier, in: scope)
    #expect(claimedBarriers.invocationIDs == [ids[1], ids[4]])
    let blocked = try session.consumeInOrder([opening, closing], mode: .strict, in: scope)
    #expect(blocked == nil)

    let first = try #require(try session.consumeInOrder([opening, closing], mode: .relative, in: scope))
    #expect(first.scope == scope)
    #expect(first.invocationIDs == [ids[0], ids[2]])
    #expect(first.watermark == history.watermark)
    let second = try #require(try session.consumeInOrder([opening, closing], mode: .relative, in: scope))
    #expect(second.invocationIDs == [ids[3], ids[5]])
    #expect(try session.consumeInOrder([opening, closing], mode: .relative, in: scope) == nil)
    let fullyClaimed = try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope)
    #expect(fullyClaimed.passed)

    let independent = session.consumptionScope(named: "completed greetings")
    #expect(try session.consumeInOrder([closing, opening], mode: .strict, phase: .threw, in: independent) == nil)
    let adjacentReturns = try #require(try session.consumeInOrder(
        [closing, opening], mode: .strict, phase: .returned, in: independent
    ))
    #expect(adjacentReturns.invocationIDs == [ids[2], ids[3]])
    let unclaimedClosing = try session.consume(.all, for: closing, in: independent)
    #expect(unclaimedClosing.invocationIDs == [ids[5]])

    #expect(session.snapshot() == history)
    #expect(openingMock.verify.greeting(for: .any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(openingMock.verify.greeting(.any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(closingMock.verify.greeting(for: .any, phase: .returned).wasCalled(.exactly(2)).passed)
}
