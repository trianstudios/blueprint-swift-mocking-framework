import BlueprintMocking
import InterfaceDomain

@main
struct IndependentConsumer {
    static func main() {
        let reporter = FailureReporter { issue in preconditionFailure("Unexpected issue: \(issue)") }
        let mock = ImportedDirectoryMock(failureReporter: reporter) { stubs in
            let rule: SyncStub<String, String> = stubs.lookup(id: .equal("sean"))
            rule.willAnswer { "hello " + $0 }
        }
        precondition(mock.verify.lookup(id: .any).wasCalled(.never).passed)
        precondition(importedLookup(mock, id: "sean") == "hello sean")
        precondition(mock.verify.lookup(id: .equal("sean"), phase: .returned).wasCalled(.once).passed)
        print("GEN003-A probe passed: binary call compiled from textual public interface")
    }
}
