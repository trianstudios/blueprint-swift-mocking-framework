import BlueprintMocking
import PhaseDomain
import XCTest

final class PhaseContextTests: XCTestCase {
    func testGeneratedWitnessUsesDomainConfiguration() {
        #if PROBE_EXPECTS_INT
        #if BLUEPRINT_DOMAIN_INT
        #error("The test target must not have the source module's Int flag")
        #endif
        let expected = 42
        #else
        #if !BLUEPRINT_DOMAIN_INT
        #error("The test target must have the source module's opposing Int flag")
        #endif
        let expected = "forty-two"
        #endif
        let mock = LookupMock(failureReporter: FailureReporter { XCTFail($0.message) }) { stubs in
            stubs.lookup(key: .equal("row")).willReturn(expected)
        }
        let dependency: any Lookup = mock
        XCTAssertEqual(dependency.lookup(key: "row"), expected)
        XCTAssertTrue(mock.verify.lookup(key: .equal("row"), phase: .returned).wasCalled(.once).passed)
        print("PASS: DX007 native \(type(of: expected))")
    }
}
