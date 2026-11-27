import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class OwnershipMockHolder {
    weak var mock: ConsumingTicketReceiverMock?
}

@Test @MainActor func GEN032_generatedConsumingInputProjectsBorrowAndDestroysOnce() throws {
    let session = MockSession()
    let log = OwnershipDestructionLog()
    let holder = OwnershipMockHolder()
    let mock = ConsumingTicketReceiverMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") },
        session: session,
        projectingInput: { (ticket: borrowing OwnershipTicket) in
            #expect(session.snapshot().activeInvocationCount == 1)
            let id = ticket.projectedID()
            let during = MainActor.assumeIsolated {
                holder.mock?.verify.receive(.equal(id)).wasCalled(.never)
            }
            #expect(during?.status == .incompleteHistory)
            #expect(during?.pendingInvocationIDs.count == 1)
            #expect(during?.captures.isEmpty == true)
            return id
        }
    ) { stubs in
        stubs.receive(.equal(7)).willAnswer { (ticket: consuming OwnershipTicket) in
            #expect(session.snapshot().activeInvocationCount == 1)
            return ticket.projectedID() + 1
        }
        stubs.receive(.equal(9)).willReturn(90)
        stubs.status().willReturn("ordinary")
    }
    holder.mock = mock
    defer { holder.mock = nil }
    let receiver: any ConsumingTicketReceiver = mock
    let first = OwnershipTicket(id: 7, log: log)
    let firstResult = receiver.receive(consume first)
    #expect(firstResult == 8)
    #expect(log.destroyedIDs == [7])

    let secondResult = receiver.receive(OwnershipTicket(id: 9, log: log))
    #expect(secondResult == 90)
    #expect(log.destroyedIDs == [7, 9])
    #expect(receiver.status() == "ordinary")

    let firstCheck = mock.verify.receive(.equal(7), phase: .returned).wasCalled(.once)
    #expect(firstCheck.passed)
    #expect(firstCheck.captures.map(\.value) == [7])
    #expect(mock.verify.receive(.equal(9)).wasCalled(.once).passed)
    #expect(mock.verify.receive(.equal(17)).wasCalled(.never).passed)
    let beforeReset = session.snapshot()
    #expect(beforeReset.events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .returned])
    let endpoint = beforeReset.events.first?.endpoint
    #expect(endpoint?.rawValue.contains("consuming ConsumerDomain.OwnershipTicket") == true)
    #expect(beforeReset.events.prefix(4).allSatisfy { $0.endpoint == endpoint })
    #expect(beforeReset.activeInvocationCount == 0)

    _ = try session.resetHistory()
    #expect(mock.verify.receive(.any).wasCalled(.never).passed)
    _ = try session.finishIfQuiescent()
    #expect(log.destroyedIDs == [7, 9])
}
