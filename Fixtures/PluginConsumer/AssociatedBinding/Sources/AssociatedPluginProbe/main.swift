import AssociatedPluginDomain
import AssociatedPluginMocks
import BlueprintMocking

func fixtureValue(_: String.Type) -> String { "loaded from configuration" }
func fixtureValue(_: Int.Type) -> Int { 17 }

let expected = fixtureValue(AssociatedLookupMock.Element.self)
let saved = StoredProperty<AssociatedLookupMock.Element?>(nil)
let mock = AssociatedLookupMock(failureReporter: FailureReporter { issue in
    fatalError(issue.message)
}) { stubs in
    stubs.load(key: .equal("row")).willReturn(expected)
    stubs.save(.equal(expected)).willAnswer { value in saved.set(value) }
}

let directory: any AssociatedLookup<AssociatedLookupMock.Element> = mock
precondition(refresh(directory: directory, key: "row") == expected)
precondition(saved.get() == expected)
precondition(mock.verify.load(key: .equal("row"), phase: .returned).wasCalled(.once).passed)
precondition(mock.verify.save(.equal(expected), phase: .returned).wasCalled(.once).passed)
print("BLUEPRINT_CONFIGURED_BINDING \(String(reflecting: AssociatedLookupMock.Element.self))")
print("PASS: DX004 plugin-generated mock compiled and ran")
