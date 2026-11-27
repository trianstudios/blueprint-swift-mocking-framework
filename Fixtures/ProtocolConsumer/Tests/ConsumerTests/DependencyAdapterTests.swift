import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func SYS005_checkoutServiceUsesLiveDependencyAdapters() {
    let catalog = ProductCatalogAdapter(ProductCatalog(prices: ["SKU-7": 140]))
    let discount = BasketCreditAdapter(BasketCredit(amount: 25))
    let formatter = CanonicalSKUAdapter()
    let service = CheckoutQuoteService(catalog: catalog, discount: discount, formatter: formatter)
    let rawSKU = "  sku-7  "

    #expect(formatter.normalize(rawSKU) == "SKU-7")
    #expect(catalog.price(for: "SKU-7") == 140)
    #expect(discount.credit(for: 140) == 25)
    #expect(service.quote(for: rawSKU) == 115)
}

@Test func SYS005_generatedAdapterMocksOnlyRecordCallsThroughProtocols() {
    let session = MockSession()
    let rawSKU = "  mix-7  "
    let normalizedSKU = "FIXTURE-SKU"
    let subtotal = 120
    let formatter = SKUFormattingMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.normalize(.equal(rawSKU)).willReturn(normalizedSKU)
    }
    let catalog = CatalogPricingMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.price(for: .equal(normalizedSKU)).willReturn(subtotal)
    }
    let discount = BasketDiscountMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.credit(for: .equal(subtotal)).willReturn(20)
    }
    let service = CheckoutQuoteService(catalog: catalog, discount: discount, formatter: formatter)
    #expect(service.quote(for: rawSKU) == 100)

    #expect(formatter.verify.normalize(.equal(rawSKU), phase: .returned).wasCalled(.once).passed)
    #expect(catalog.verify.price(for: .equal(normalizedSKU), phase: .returned).wasCalled(.once).passed)
    #expect(discount.verify.credit(for: .equal(subtotal), phase: .returned).wasCalled(.once).passed)

    let mockedWorkflow = session.snapshot()
    #expect(mockedWorkflow.activeInvocationCount == 0)
    #expect(mockedWorkflow.events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .returned])

    let originalCatalog = ProductCatalog(prices: [normalizedSKU: 140])
    let originalDiscount = BasketCredit(amount: 5)
    #expect(canonicalSKU(rawSKU) == "MIX-7")
    #expect(originalCatalog.price(for: normalizedSKU) == 140)
    #expect(originalDiscount.credit(for: subtotal) == 5)
    #expect(session.snapshot() == mockedWorkflow)

    #expect(formatter.verify.normalize(.equal(rawSKU)).wasCalled(.once).passed)
    #expect(catalog.verify.price(for: .equal(normalizedSKU)).wasCalled(.once).passed)
    #expect(discount.verify.credit(for: .equal(subtotal)).wasCalled(.once).passed)
}
