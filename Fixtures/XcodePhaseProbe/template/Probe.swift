import BlueprintMocking
import PhaseDomain

@main
enum XcodePhaseProbe {
    static func main() {
        let mocked = LookupMock(failureReporter: FailureReporter { fatalError($0.message) }) { stubs in
            stubs.lookup(key: .equal("row")).willReturn("ready")
        }
        let client = PhaseDirectory(lookup: mocked)
        precondition(client.label(for: "row") == "ready")
        precondition(mocked.verify.lookup(key: .equal("row"), phase: .returned).wasCalled(.once).passed)
        print("PASS: DX008 Xcode generated source compiled and ran")
    }
}
