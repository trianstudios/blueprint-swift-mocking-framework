import Foundation

public final class ProductCatalog: Sendable {
    private let prices: [String: Int]

    public init(prices: [String: Int]) {
        self.prices = prices
    }

    public func price(for sku: String) -> Int {
        prices[sku, default: 0]
    }
}

public struct BasketCredit: Sendable {
    private let amount: Int

    public init(amount: Int) {
        self.amount = amount
    }

    public func credit(for subtotal: Int) -> Int {
        min(amount, subtotal)
    }
}

public func canonicalSKU(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

public protocol CatalogPricing: Sendable {
    func price(for sku: String) -> Int
}

public protocol BasketDiscount: Sendable {
    func credit(for subtotal: Int) -> Int
}

public protocol SKUFormatting: Sendable {
    func normalize(_ raw: String) -> String
}

public struct ProductCatalogAdapter: CatalogPricing {
    private let catalog: ProductCatalog

    public init(_ catalog: ProductCatalog) {
        self.catalog = catalog
    }

    public func price(for sku: String) -> Int {
        catalog.price(for: sku)
    }
}

public struct BasketCreditAdapter: BasketDiscount {
    private let credit: BasketCredit

    public init(_ credit: BasketCredit) {
        self.credit = credit
    }

    public func credit(for subtotal: Int) -> Int {
        credit.credit(for: subtotal)
    }
}

public struct CanonicalSKUAdapter: SKUFormatting {
    public init() {}

    public func normalize(_ raw: String) -> String {
        canonicalSKU(raw)
    }
}

public struct CheckoutQuoteService: Sendable {
    private let catalog: any CatalogPricing
    private let discount: any BasketDiscount
    private let formatter: any SKUFormatting

    public init(catalog: any CatalogPricing, discount: any BasketDiscount, formatter: any SKUFormatting) {
        self.catalog = catalog
        self.discount = discount
        self.formatter = formatter
    }

    public func quote(for rawSKU: String) -> Int {
        let sku = formatter.normalize(rawSKU)
        let subtotal = catalog.price(for: sku)
        return subtotal - discount.credit(for: subtotal)
    }
}
