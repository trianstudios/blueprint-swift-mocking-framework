import BlueprintMocking
import InterfaceDomain

@main
struct IndependentInheritedConsumer {
    static func main() {
        let issues = StoredProperty<[MockIssue]>([])
        let mock = InheritedImportedDirectoryMock(failureReporter: FailureReporter { issue in
            issues.set(issues.get() + [issue])
        }) { stubs in
            let enabled: SyncStub<String, Bool> = stubs.enabled(.equal("row"))
            enabled.willReturn(true)
            let lookup: SyncStub<String, Int> = stubs.lookup(.equal("row"))
            lookup.willReturn(42)
        }
        let parent: any ImportedDirectoryBase = mock
        precondition(parent.enabled("row"))
        precondition(importedInheritedLookup(mock, id: "row") == 42)
        precondition(mock.verify.enabled(.equal("row"), phase: .returned).wasCalled(.exactly(2)).passed)
        precondition(mock.verify.lookup(.equal("row"), phase: .returned).wasCalled(.once).passed)
        precondition(mock.verify.mark(.equal("row")).wasCalled(.once).passed)
        let recorded = issues.get()
        precondition(recorded.count == 1)
        precondition(recorded[0].endpoint.rawValue == "schema1|InterfaceDomain.InheritedImportedDirectory|mark(_:Swift.String)->Void|Sendable")
        precondition(recorded[0].source.fileID == "InterfaceDomain/" + CommandLine.arguments[1])
        precondition(recorded[0].source.filePath == CommandLine.arguments[1])
        precondition(recorded[0].source.line == Int(CommandLine.arguments[2]))
        precondition(recorded[0].source.column == 1)
        print("GEN003 inheritance probe passed: binary call and parent source from textual public interface")
    }
}
