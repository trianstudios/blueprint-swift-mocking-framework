import ConsumerDomain
import ConsumerDoubles

public func eraseOwnedResult(_ mock: FreshOwnedTicketSourceMock) -> Any {
    mock.issue(0)
}
