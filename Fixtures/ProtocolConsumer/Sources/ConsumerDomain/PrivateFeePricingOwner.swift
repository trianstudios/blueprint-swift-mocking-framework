public protocol PrivateFeePricing: Sendable {
    func quote(base: Int) -> Int
}

public final class OwnedFeeRules: Sendable {
    private let surcharge: Int

    public init(surcharge: Int) {
        self.surcharge = surcharge
    }

    private func addSurcharge(to base: Int) -> Int {
        base + surcharge
    }
}

private struct OwnerFileFeePricing: PrivateFeePricing {
    let adjustedQuote: @Sendable (Int) -> Int

    func quote(base: Int) -> Int {
        adjustedQuote(base)
    }
}

public extension OwnedFeeRules {
    func makePricingAdapter() -> any PrivateFeePricing {
        OwnerFileFeePricing { [self] base in addSurcharge(to: base) }
    }
}

public struct PrivateFeeQuoteService: Sendable {
    private let pricing: any PrivateFeePricing

    public init(pricing: any PrivateFeePricing) {
        self.pricing = pricing
    }

    public func total(base: Int) -> Int {
        pricing.quote(base: base)
    }
}
