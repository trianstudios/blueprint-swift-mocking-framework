import ConsumerDomain
import ConsumerDoubles

public func useAfterConsume(_ mock: ConsumingTicketReceiverMock, ticket: consuming OwnershipTicket) -> Int {
    _ = mock.receive(consume ticket)
    return ticket.projectedID()
}
