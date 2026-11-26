import Foundation
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

private enum ForeignCallContext: String, Sendable {
    case detached
    case inherited
    case thread
}

private enum LateCallCompletion: Sendable {
    case queued
    case reportedFromInheritedCase(MockIssue)
}

private struct LateOwnerWork: Sendable {
    let nativeID: Test.ID
    let session: MockSession
    let frozen: SessionSnapshot
    let completion: AsyncStream<LateCallCompletion>
    let issues: AsyncStream<MockIssue>
}

private let lateOwnerWork = AsyncStream<LateOwnerWork>.makeStream(bufferingPolicy: .bufferingNewest(1))

private func bridgeReleased(_ releasePath: String) -> Bool {
    guard let gate = FileHandle(forReadingAtPath: releasePath) else { return false }
    defer { try? gate.close() }
    return (try? gate.readToEnd()) == Data("release\n".utf8)
}

private func drainOneIssue(_ issues: AsyncStream<MockIssue>) async -> MockIssue? {
    var received = issues.makeAsyncIterator()
    guard let issue = await received.next(), await received.next() == nil else { return nil }
    return issue
}

private func beginLateWork(
    context: ForeignCallContext,
    releasePath: String,
    ownerID: Test.ID,
    issues: AsyncStream<MockIssue>,
    invoke: @escaping @Sendable () -> Bool
) -> AsyncStream<LateCallCompletion> {
    let (completion, result) = AsyncStream<LateCallCompletion>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let runTask: @Sendable () async -> Void = {
        defer { result.finish() }
        let released = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: bridgeReleased(releasePath))
            }
        }
        guard released, invoke() else { return }
        if context == .inherited {
            guard let issue = await drainOneIssue(issues),
                  Test.current?.id == ownerID, Test.Case.current?.isParameterized == true else { return }
            // This task still carries the native context of the owner whose case ended.
            await FailureReporter.reportAtSwiftTestingRunLevel(issue)
            result.yield(.reportedFromInheritedCase(issue))
        } else {
            result.yield(.queued)
        }
    }
    switch context {
    case .detached:
        Task.detached { await runTask() }
    case .inherited:
        Task { await runTask() }
    case .thread:
        Thread.detachNewThread {
            defer { result.finish() }
            if bridgeReleased(releasePath), invoke() { result.yield(.queued) }
        }
    }
    return completion
}

// An isolated driver releases the captured work after receiving native testCaseEnded for owner-A.
@Test(.timeLimit(.minutes(1)), arguments: ["owner-A", "peer-B"])
func DX023_closedParameterizedReporterAttribution(_ scenario: String) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let bridgePath = environment["BLUEPRINT_CLOSED_OWNER_BRIDGE"] else { return }
    let context = try #require(environment["BLUEPRINT_CLOSED_OWNER_CONTEXT"].flatMap(ForeignCallContext.init))
    let nativeID = try #require(Test.current?.id)
    try #require(Test.Case.current?.isParameterized == true)
    let session = MockSession()
    let (issues, inbox) = AsyncStream<MockIssue>.makeStream()
    let scope = TypeSubscriptDirectoryMock.makeTypeScope(
        failureReporter: FailureReporter { inbox.yield($0) }, session: session
    ) {
        $0.set_subscript(.equal(7), newValue: .equal(1)).willReturn(())
    }

    if scenario == "owner-A" {
        defer { lateOwnerWork.continuation.finish() }
        scope.withValue { TypeSubscriptDirectoryMock[7] = 1 }
        let frozen = try session.finishIfQuiescent()
        try #require(frozen.events.map(\.phase) == [.admitted, .returned])
        let completion = beginLateWork(
            context: context, releasePath: bridgePath + "/release", ownerID: nativeID, issues: issues
        ) {
            defer { inbox.finish() }
            let matchesNativeContext: Bool
            switch context {
            case .inherited:
                matchesNativeContext = Test.current?.id == nativeID && Test.Case.current?.isParameterized == true
            case .detached, .thread:
                matchesNativeContext = Test.current == nil && Test.Case.current == nil
            }
            scope.withValue { TypeSubscriptDirectoryMock[7] = 2 }
            return matchesNativeContext
        }
        lateOwnerWork.continuation.yield(.init(
            nativeID: nativeID, session: session, frozen: frozen, completion: completion, issues: issues
        ))
        return
    }

    try await scope.withValue {
        TypeSubscriptDirectoryMock[7] = 1
        let baseline = session.snapshot()
        let peerReady = URL(fileURLWithPath: bridgePath + "/peer-ready")
        try Data(String(describing: nativeID).utf8).write(to: peerReady, options: .atomic)
        var owners = lateOwnerWork.stream.makeAsyncIterator()
        let owner = try #require(await owners.next())
        try #require(owner.nativeID == nativeID)
        try #require(owner.session.id != session.id)

        var completion = owner.completion.makeAsyncIterator()
        let lateCall = try #require(await completion.next())
        try #require(await completion.next() == nil)
        let orphan: MockIssue
        switch lateCall {
        case .queued:
            try #require(context != .inherited)
            orphan = try #require(await drainOneIssue(owner.issues))
            // Drain from the live peer, then explicitly report outside its runner context.
            await FailureReporter.reportAtSwiftTestingRunLevel(orphan)
        case .reportedFromInheritedCase(let issue):
            try #require(context == .inherited)
            orphan = issue
        }
        try #require(orphan.kind == .unexpectedCall)
        try #require(orphan.message.hasSuffix(" in a finished mock session"))
        try #require(owner.session.snapshot() == owner.frozen)
        inbox.finish()
        var peerIssues = issues.makeAsyncIterator()
        try #require(await peerIssues.next() == nil)
        try #require(baseline.events.map(\.phase) == [.admitted, .returned])
        try #require(session.snapshot() == baseline)
        try #require(Test.current?.id == nativeID)
        try #require(Test.Case.current?.isParameterized == true)
        print("PASS: DX023 owner closed while peer stayed active, one neutral issue")
    }
}
