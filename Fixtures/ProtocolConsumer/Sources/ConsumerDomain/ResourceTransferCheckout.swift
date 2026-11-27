public protocol ResourceTransferCheckout: Sendable {
    func issue(_ key: Int) -> FreshOwnedTicket
    func redeem(_ ticket: consuming FreshOwnedTicket) -> Int
}

public struct ResourceTransferClient: Sendable {
    private let checkout: any ResourceTransferCheckout

    public init(checkout: any ResourceTransferCheckout) { self.checkout = checkout }

    public func redeemIssued(_ key: Int) -> Int {
        let ticket = checkout.issue(key)
        return checkout.redeem(consume ticket)
    }
}
