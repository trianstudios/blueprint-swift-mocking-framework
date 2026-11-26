import BlueprintMocking
import OfflineDomain

let mock = LookupMock(failureReporter: FailureReporter { issue in
    fatalError("Unexpected mock issue: \(issue.kind)")
}) { stubs in
    stubs.value(for: .equal("network")).willReturn("offline")
}
let dependency: any Lookup = mock
precondition(dependency.value(for: "network") == "offline")
precondition(mock.verify.value(for: .equal("network"), phase: .returned).wasCalled(.once).passed)
let _: BlueprintMockingGeneratedIndex.Shard.Type = BlueprintMockingGeneratedIndex.Shard.self
print("PASS: DX020 configured generated consumer")
