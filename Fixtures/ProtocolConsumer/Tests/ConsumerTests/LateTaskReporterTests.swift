import Foundation
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

// Run in an isolated subprocess. The one native runner failure is deliberate.
@Test(.timeLimit(.minutes(1)))
func DX023_lateTypeScopeTaskKeepsOwningReporter() async throws {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE"] == "1" else { return }
    let (ownerIssues, ownerIssue) = AsyncStream<MockIssue>.makeStream()
    let (otherIssues, otherIssue) = AsyncStream<MockIssue>.makeStream()
    let sessionA = MockSession()
    let sessionB = MockSession()
    let scopeA = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: FailureReporter { issue in
        ownerIssue.yield(issue)
        FailureReporter.swiftTesting.report(issue)
    }, session: sessionA) { stubs in
        stubs.set_subscript(.any, newValue: .any).willReturn(())
    }
    let scopeB = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: FailureReporter { issue in
        otherIssue.yield(issue)
        FailureReporter.swiftTesting.report(issue)
    }, session: sessionB) { stubs in
        stubs.set_subscript(.any, newValue: .any).willReturn(())
    }

    let (gate, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { release.finish() }
    let late = scopeA.withValue {
        TypeSubscriptDirectoryMock[7] = 1
        return Task {
            var token = gate.makeAsyncIterator()
            guard await token.next() != nil else { return }
            TypeSubscriptDirectoryMock[7] = 2
        }
    }
    let finalA = try sessionA.finishIfQuiescent()
    let baselineB = await scopeB.withValue {
        TypeSubscriptDirectoryMock[7] = 3
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

    try #require(reportedByA.count == 1)
    try #require(reportedByB.isEmpty)
    try #require(reportedByA[0].kind == .unexpectedCall)
    try #require(reportedByA[0].message.hasSuffix(" in a finished mock session"))
    try #require(finalA.isFinished)
    try #require(finalA.events.map(\.phase) == [.admitted, .returned])
    try #require(baselineB.events.map(\.phase) == [.admitted, .returned])
    try #require(sessionA.snapshot() == finalA)
    try #require(sessionB.snapshot() == baselineB)
    print("PASS: DX023 late type task retained its owning reporter")
}
