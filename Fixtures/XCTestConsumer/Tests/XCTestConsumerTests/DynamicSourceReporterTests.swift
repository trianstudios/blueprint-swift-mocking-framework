#if os(macOS)
import BlueprintMocking
import BlueprintMockingXCTest
import Foundation
import XCTest

private final class NeutralIssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MockIssue] = []

    var observed: [MockIssue] { lock.withLock { storage } }

    func collect(_ issue: MockIssue) {
        lock.withLock { storage.append(issue) }
    }
}

private final class DynamicSourceObserver: NSObject, XCTestObservation {
    struct Failure: Equatable {
        let file: String?
        let line: Int?
        let message: String
    }

    private let target: ObjectIdentifier
    private let lock = NSLock()
    private var failures: [Failure] = []

    init(target: XCTestCase) {
        self.target = ObjectIdentifier(target)
    }

    var observed: [Failure] { lock.withLock { failures } }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        guard ObjectIdentifier(testCase) == target else { return }
        let location = issue.sourceCodeContext.location
        let failure = Failure(file: location?.fileURL.path, line: location?.lineNumber,
                              message: issue.compactDescription)
        lock.withLock { failures.append(failure) }
    }
}

final class DynamicSourceReporterTests: XCTestCase {
    @objc func testRecordsDynamicSourceOnExplicitActiveCase() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLUEPRINT_XCTEST_DYNAMIC_SOURCE_FAILURE"] == "1")
        let collector = NeutralIssueCollector()
        let mock = LookupMock(failureReporter: FailureReporter { collector.collect($0) }) { _ in }
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DynamicOrigin.swift").path
        let line = 147
        let result = mock.verify.name(for: .any).wasCalled(
            .once, fileID: "DynamicFixture/DynamicOrigin.swift", filePath: path, line: line, column: 23
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(collector.observed.count, 1)
        let issue = try XCTUnwrap(collector.observed.first)
        XCTAssertNil(issue.source.staticFilePath)

        let observer = DynamicSourceObserver(target: self)
        XCTestObservationCenter.shared.addTestObserver(observer)
        defer { XCTestObservationCenter.shared.removeTestObserver(observer) }

        let idle = XCTestCase(selector: #selector(testRecordsDynamicSourceOnExplicitActiveCase))
        XCTAssertThrowsError(try FailureReporter.recordXCTestIssue(issue, in: idle)) {
            XCTAssertEqual($0 as? XCTestCaseRecordingError, .inactiveCase)
        }
        XCTAssertTrue(observer.observed.isEmpty)

        try FailureReporter.recordXCTestIssue(issue, in: self)
        let expected = DynamicSourceObserver.Failure(file: path, line: line, message: issue.message)
        let recorded = observer.observed
        XCTAssertEqual(recorded, [expected])
        if recorded == [expected] {
            print("PASS: XCTest observed the exact dynamic origin on the explicit owning case")
        }
    }
}
#endif
