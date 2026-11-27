import ConsumerDomain

public func cannotRedeemIssuedTicketTwice(_ checkout: any ResourceTransferCheckout) {
    let ticket = checkout.issue(7)
    _ = checkout.redeem(consume ticket)
    _ = checkout.redeem(consume ticket)
}
