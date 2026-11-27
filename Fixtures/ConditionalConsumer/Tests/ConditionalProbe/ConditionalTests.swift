import BlueprintMocking
import BlueprintMockingTesting
import ConditionalDomain
import ConditionalDoubles
import Testing

#if !BLUEPRINT_PROBE_FIXTURE
#error("The consumer target must keep its own independent compilation condition")
#endif

private func expectedValue(_: (any ConditionalDirectory) -> Int) -> Int { 17 }
private func expectedValue(_: (any ConditionalDirectory) -> String) -> String { "selected by domain" }
private func expectedValue(_: (any ConditionalDirectory) -> Bool) -> Bool { true }

@Test func GEN004_domainTargetSelectsConditionalWitness() {
    let expected = expectedValue { $0.value() }
    let invertedExpected = expectedValue { $0.inverted() }
    let mock = ConditionalDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.value().willReturn(expected)
        stubs.inverted().willReturn(invertedExpected)
    }
    let domain: any ConditionalDirectory = mock
    let result = domain.value()
    let inverted = domain.inverted()
    #expect(result == expected)
    #expect(inverted == invertedExpected)
    #expect(mock.verify.value(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.inverted(phase: .returned).wasCalled(.once).passed)
    print("BLUEPRINT_CONDITIONAL_DOMAIN \(String(reflecting: type(of: result))) \(result)")
    print("BLUEPRINT_NEGATED_CONDITIONAL_DOMAIN \(String(reflecting: type(of: inverted))) \(inverted)")
}
