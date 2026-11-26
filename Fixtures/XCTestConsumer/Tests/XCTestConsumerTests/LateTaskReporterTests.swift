import Foundation
import XCTest
import BlueprintMocking
import BlueprintMockingXCTest

final class LateTaskReporterTests: XCTestCase {
    // Run in an isolated subprocess. The one native runner failure is deliberate.
    func testLateTypeScopeTaskKeepsOwningReporter() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE"] == "1")
        let (ownerIssues, ownerIssue) = AsyncStream<MockIssue>.makeStream()
        let (otherIssues, otherIssue) = AsyncStream<MockIssue>.makeStream()
        let sessionA = MockSession()
        let sessionB = MockSession()
        let scopeA = LookupMock.makeTypeScope(failureReporter: FailureReporter { issue in
            ownerIssue.yield(issue)
            FailureReporter.xctest.report(issue)
        }, session: sessionA) { stubs in
            stubs.set_subscript(.any, newValue: .any).willReturn(())
        }
        let scopeB = LookupMock.makeTypeScope(failureReporter: FailureReporter { issue in
            otherIssue.yield(issue)
            FailureReporter.xctest.report(issue)
        }, session: sessionB) { stubs in
            stubs.set_subscript(.any, newValue: .any).willReturn(())
        }

        let (gate, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { release.finish() }
        let late = scopeA.withValue {
            LookupMock[7] = 1
            return Task {
                var token = gate.makeAsyncIterator()
                guard await token.next() != nil else { return }
                LookupMock[7] = 2
            }
        }
        let finalA = try sessionA.finishIfQuiescent()
        let baselineB = await scopeB.withValue {
            LookupMock[7] = 3
            let beforeRelease = sessionB.snapshot()
            release.yield(())
            release.finish()
            await late.value
            return beforeRelease
        }

        ownerIssue.finish()
        otherIssue.finish()
        var reportedByA: [MockIssue] = []
        var reportedByB: [MockIssue] = []
        for await issue in ownerIssues { reportedByA.append(issue) }
        for await issue in otherIssues { reportedByB.append(issue) }

        guard reportedByA.count == 1, reportedByB.isEmpty,
              reportedByA[0].kind == .unexpectedCall,
              reportedByA[0].message.hasSuffix(" in a finished mock session"),
              finalA.isFinished, finalA.events.map(\.phase) == [.admitted, .returned],
              baselineB.events.map(\.phase) == [.admitted, .returned],
              sessionA.snapshot() == finalA, sessionB.snapshot() == baselineB else {
            XCTFail("Expected one finished-session issue from scope A and unchanged histories in both scopes")
            return
        }
        print("PASS: DX023 late type task retained its owning reporter")
    }
}
