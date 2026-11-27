#if os(macOS)
import BlueprintMocking
import XCTest

public enum XCTestCaseRecordingError: Error, Equatable, Sendable {
    case inactiveCase
}

extension FailureReporter {
    /// Records a collected neutral issue on its explicitly supplied, active XCTest case.
    /// Call on the owning runner path before the case finishes. The native location
    /// accepts dynamic paths as well as locations that originated as Swift literals.
    public static func recordXCTestIssue(
        _ issue: MockIssue, in testCase: XCTestCase
    ) throws(XCTestCaseRecordingError) {
        guard let run = testCase.testRun as? XCTestCaseRun,
              run.startDate != nil, run.stopDate == nil else { throw .inactiveCase }

        testCase.record(nativeXCTestIssue(issue))
    }
}
#endif
