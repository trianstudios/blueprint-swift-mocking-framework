import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

public func cannotReplayAnIssuedTicket() -> ResourceTransferCheckoutMock {
    ResourceTransferCheckoutMock(failureReporter: FailureReporter { _ in }, projectingInput: { $0.number }) { stubs in
        let previous = FreshOwnedTicket(number: 701) { _ in }
        stubs.issue(.any).willProduce { [previous] _ in consume previous }
    }
}
