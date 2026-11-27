import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

public func escapeBorrow(_ submit: @escaping @Sendable (@escaping () -> Int) -> Void)
    -> ConsumingTicketReceiverMock {
    ConsumingTicketReceiverMock(failureReporter: FailureReporter { _ in },
                               projectingInput: { (ticket: borrowing OwnershipTicket) in
        submit { ticket.projectedID() }
        return 0
    }) { _ in }
}
