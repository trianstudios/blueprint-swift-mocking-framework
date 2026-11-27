import ConsumerDomain
import ConsumerDoubles

public func consumeTwice(_ mock: ConsumingTicketReceiverMock, ticket: consuming OwnershipTicket) {
    _ = mock.receive(consume ticket)
    _ = mock.receive(consume ticket)
}
