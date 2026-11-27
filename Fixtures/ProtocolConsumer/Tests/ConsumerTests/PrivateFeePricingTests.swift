import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN031_ownerFilePrivateSeamUsesLiveAndGeneratedAdapters() {
    let owner = OwnedFeeRules(surcharge: 14)
    let live = PrivateFeeQuoteService(pricing: owner.makePricingAdapter())
    #expect(live.total(base: 100) == 114)

    let session = MockSession()
    let generated = PrivateFeePricingMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.quote(base: .equal(100)).willReturn(90)
    }
    let substituted = PrivateFeeQuoteService(pricing: generated)
    #expect(substituted.total(base: 100) == 90)
    #expect(generated.verify.quote(base: .equal(100), phase: .returned).wasCalled(.once).passed)
    let mocked = session.snapshot()
    #expect(mocked.activeInvocationCount == 0)
    #expect(mocked.events.map(\.phase) == [.admitted, .returned])

    #expect(live.total(base: 100) == 114)
    #expect(session.snapshot() == mocked)
}
