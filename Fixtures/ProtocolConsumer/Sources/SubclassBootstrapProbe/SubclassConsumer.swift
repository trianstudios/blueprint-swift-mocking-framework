import BlueprintMocking
import BootstrapDomain

@main
@MainActor
struct Probe {
    static func main() {
        let real = BootstrapRenderer(seed: "control")
        precondition(real.bootstrapValue == "real:control")
        let reporter = FailureReporter { issue in fatalError(issue.message) }
        let mock = BootstrapRendererMock(seed: "same", failureReporter: reporter) { setup in
            setup.render(.equal("same")).willReturn("stub:same")
        }
        precondition(mock.bootstrapValue == "real:same")
        precondition(mock.verify.render(.any).wasCalled(.never).passed)

        let throughBase: BootstrapRenderer = mock
        precondition(throughBase.render("outside") == "real:outside")
        precondition(throughBase.envelope("same") == "outer:stub:same")
        precondition(throughBase.render("same") == "stub:same")
        precondition(mock.verify.render(.equal("same"), phase: .returned).wasCalled(.exactly(2)).passed)
        precondition(mock.verify.render(.equal("outside"), phase: .returned, origin: .forwarded).wasCalled(.once).passed)
        weak var released: BootstrapRendererMock?
        do {
            let temporary = BootstrapRendererMock(seed: "released", failureReporter: reporter) { _ in }
            released = temporary
            precondition(released != nil)
        }
        precondition(released == nil, "the endpoint retained its mock")
        print("PASS: initializer reentry reached the override; bootstrap forwarded before ready, later self-call used the stub, and miss remained forwarded")
    }
}
