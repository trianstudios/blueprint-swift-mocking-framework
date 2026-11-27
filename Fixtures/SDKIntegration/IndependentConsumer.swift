import BlueprintMocking
import FrozenSDK

@MainActor
private struct SDKCheckout {
    let renderer: BootstrapRenderer
    let pricing: any FrozenQuoteSDKFacade

    func receipt(value: Int) -> String {
        renderer.envelope(String(pricing.quote(value: value)))
    }
}

@main @MainActor
struct IndependentSDKConsumer {
    static func main() {
        let reporter = FailureReporter { issue in fatalError(issue.message) }
        let sdk = FrozenQuoteSDK(surcharge: 4)
        let renderer = BootstrapRendererMock(seed: "startup", failureReporter: reporter) { stubs in
            stubs.render(.equal("99")).willReturn("promotional receipt")
        }
        precondition(renderer.bootstrapValue == "real:startup")
        precondition(renderer.verify.render(.any).wasCalled(.never).passed)

        let production = SDKCheckout(renderer: renderer, pricing: FrozenQuoteSDKFacadeLive(sdk: sdk))
        precondition(production.receipt(value: 10) == "outer:real:14")
        precondition(renderer.verify.render(.equal("14"), phase: .returned, origin: .forwarded).wasCalled(.once).passed)

        let session = MockSession()
        let mock = FrozenQuoteSDKFacadeMock(failureReporter: reporter, session: session) { stubs in
            stubs.quote(value: .equal(10)).willReturn(99)
        }
        let testing = SDKCheckout(renderer: renderer, pricing: mock)
        precondition(testing.receipt(value: 10) == "outer:promotional receipt")
        precondition(renderer.verify.render(.equal("99"), phase: .returned).wasCalled(.once).passed)
        precondition(mock.verify.quote(value: .equal(10), phase: .returned).wasCalled(.once).passed)
        precondition(sdk.quote(value: 10) == 14)
        precondition(mock.verify.quote(value: .any, phase: .admitted).wasCalled(.once).passed)
        let events = session.snapshot().events
        precondition(events.map(\.phase) == [.admitted, .returned])
        precondition(events[0].invocationID == events[1].invocationID)
        print("PASS: A3.4 SDK integration composes the open subclass and injected facade through one binary SDK")
    }
}
