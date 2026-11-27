import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

public func replayCapturedResult() -> FreshOwnedTicketSourceMock {
    FreshOwnedTicketSourceMock(failureReporter: FailureReporter { _ in }) { stubs in
        let previous = FreshOwnedTicket(number: 1) { _ in }
        stubs.issue(.any).willProduce { [previous] _ in consume previous }
    }
}
