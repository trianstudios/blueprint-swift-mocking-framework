import BlueprintMocking
import GenericMethodPluginDomain
import GenericMethodPluginMocks

let session = MockSession()
let mock = GenericMethodLookupMock(failureReporter: FailureReporter { issue in
    fatalError(issue.message)
}, session: session) { stubs in
    stubs.transform(.equal(17), as: Int.self).willReturn(42)
    stubs.transform(.equal("configured"), as: String.self).willAnswer { "result/\($0)" }
}
let directory: any GenericMethodLookup = mock
let number = transform(17, using: directory)
let text = transform("configured", using: directory)

precondition(number == 42)
precondition(text == "result/configured")
precondition(mock.verify.transform(.equal(17), as: Int.self, phase: .returned).wasCalled(.once).passed)
precondition(mock.verify.transform(.equal("configured"), as: String.self, phase: .returned).wasCalled(.once).passed)

let events = session.snapshot().events
precondition(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
precondition(events[0].endpoint.rawValue == events[2].endpoint.rawValue)
precondition(events[0].endpoint != events[2].endpoint)
precondition(events[0].invocationID == events[1].invocationID)
precondition(events[2].invocationID == events[3].invocationID)
precondition(events[0].endpoint.specialization?.typeName == String(reflecting: Int.self))
precondition(events[2].endpoint.specialization?.typeName == String(reflecting: String.self))

print("BLUEPRINT_CONFIGURED_GENERIC_METHODS \(String(reflecting: type(of: number))) \(String(reflecting: type(of: text)))")
print("PASS: DX004 plugin-generated mock compiled and ran")
