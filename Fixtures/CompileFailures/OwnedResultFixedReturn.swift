import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

public func fixedOwnedResult() -> FreshOwnedTicketSourceMock {
    FreshOwnedTicketSourceMock(failureReporter: FailureReporter { _ in }) { stubs in
        stubs.issue(.any).willReturn(FreshOwnedTicket(number: 1) { _ in })
    }
}
