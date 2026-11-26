import BlueprintMocking
import PluginDomain
import PluginMocks

func exerciseThroughProtocol(_ lookup: any Lookup) -> String {
    let value = lookup.value(for: "swiftpm")
    lookup.mark("unstubbed")
    return value
}

let reports = StoredProperty<[MockIssue]>([])
let mock = LookupMock(failureReporter: FailureReporter { issue in
    reports.set(reports.get() + [issue])
}) { stubs in
    stubs.value(for: .equal("swiftpm")).willReturn("declared build tool")
}
precondition(exerciseThroughProtocol(mock) == "declared build tool")
precondition(mock.verify.value(for: .equal("swiftpm")).wasCalled(.once).passed)
precondition(mock.verify.mark(.equal("unstubbed"), phase: .returned).wasCalled(.once).passed)

let recorded = reports.get()
precondition(recorded.count == 1 && recorded[0].kind == .unexpectedCall)
let source = recorded[0].source
print("BLUEPRINT_PLUGIN_ORIGIN \(source.fileID)|\(source.filePath)|\(source.line)|\(source.column)")
print("PASS: DX004 plugin-generated mock compiled and ran")
