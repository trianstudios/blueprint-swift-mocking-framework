import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private enum ResourceEvent: Sendable, Equatable {
    case issued(Int)
    case projected(Int)
    case redeemed(Int)
    case destroyed(Int)
}

@Test func SYS006_resourceTransferIssuesFreshTicketsAndConsumesEachExactlyOnce() throws {
    let session = MockSession()
    let timeline = StoredProperty<[ResourceEvent]>([])
    let next = StoredProperty(0)
    let mock = ResourceTransferCheckoutMock(
        failureReporter: .swiftTesting, session: session,
        projectingInput: { (ticket: borrowing FreshOwnedTicket) in
            let number = ticket.number
            timeline.set(timeline.get() + [.projected(number)])
            return number
        }
    ) { stubs in
        stubs.issue(.equal(7)).willProduce { key in
            let serial = next.get() + 1
            next.set(serial)
            let number = key * 100 + serial
            timeline.set(timeline.get() + [.issued(number)])
            return FreshOwnedTicket(number: number) { destroyed in
                timeline.set(timeline.get() + [.destroyed(destroyed)])
            }
        }
        stubs.redeem(.any).willAnswer { (ticket: consuming FreshOwnedTicket) in
            let number = ticket.number
            timeline.set(timeline.get() + [.redeemed(number)])
            return number
        }
    }
    let checkout: any ResourceTransferCheckout = mock
    let client = ResourceTransferClient(checkout: checkout)
    #expect(timeline.get().isEmpty)
    #expect(client.redeemIssued(7) == 701)
    #expect(timeline.get() == [.issued(701), .projected(701), .redeemed(701), .destroyed(701)])
    #expect(client.redeemIssued(7) == 702)
    let expected: [ResourceEvent] = [
        .issued(701), .projected(701), .redeemed(701), .destroyed(701),
        .issued(702), .projected(702), .redeemed(702), .destroyed(702)
    ]
    #expect(timeline.get() == expected)

    #expect(mock.verify.issue(.equal(7), phase: .returned).wasCalled(.exactly(2)).passed)
    let projection = mock.verify.redeem(.any, phase: .returned).wasCalled(.exactly(2))
    #expect(projection.passed)
    #expect(projection.captures.map(\.value) == [701, 702])
    let missingProjection = mock.verify.redeem(.equal(703), phase: .returned).wasCalled(.once)
    #expect(!missingProjection.passed)
    #expect(missingProjection.captures.isEmpty)

    let completed = try session.finishIfQuiescent()
    #expect(completed.activeInvocationCount == 0)
    #expect(completed.events.map(\.phase) == [.admitted, .returned, .admitted, .returned,
                                            .admitted, .returned, .admitted, .returned])
    let admissions = completed.events.filter { $0.phase == .admitted }
    let terminals = completed.events.filter { $0.phase == .returned }
    #expect(admissions.map(\.invocationID) == terminals.map(\.invocationID))
    #expect(Set(admissions.map(\.invocationID)).count == 4)
    #expect(admissions.map { $0.endpoint.rawValue.contains("|issue(") } == [true, false, true, false])
    #expect(admissions.map { $0.endpoint.rawValue.contains("|redeem(") } == [false, true, false, true])
    #expect(timeline.get() == expected)
}
