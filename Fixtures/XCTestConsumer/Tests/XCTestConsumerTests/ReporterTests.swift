import Foundation
import XCTest
import BlueprintMocking
import BlueprintMockingXCTest
import LookupDomain

final class ReporterTests: XCTestCase {
    func testPassingVerificationDoesNotRecordAnIssue() {
        let mock = LookupMock(failureReporter: .xctest) { stubs in
            stubs.name(for: .equal("one")).willReturn("Ada")
        }

        XCTAssertEqual(mock.name(for: "one"), "Ada")
        XCTAssertTrue(mock.verify.name(for: .equal("one")).wasCalled(.once).passed)
    }

    func testMismatchReportsSyncCaller() throws {
        try requireExpectedFailure()
        let mock = LookupMock(failureReporter: .xctest) { _ in }

        mock.verify.name(for: .any).wasCalled(.once) // expected XCTest failure: sync
    }

    func testMismatchReportsAsyncCaller() async throws {
        try requireExpectedFailure()
        let mock = LookupMock(failureReporter: .xctest) { stubs in
            stubs.refresh(id: .equal("one")).willReturn("Ada")
        }
        let name = try await mock.refresh(id: "one")
        XCTAssertEqual(name, "Ada")

        mock.verify.refresh(id: .any, phase: .returned).wasCalled(.exactly(2)) // expected XCTest failure: async
    }

    private func requireExpectedFailure() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLUEPRINT_XCTEST_EXPECT_FAILURE"] == "1")
    }
}
