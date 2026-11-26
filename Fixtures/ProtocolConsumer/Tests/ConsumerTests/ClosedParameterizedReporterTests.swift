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
    case flushedFromInheritedCase(OrphanFailureBatch)
}

private struct LateOwnerWork: Sendable {
    let nativeID: Test.ID
    let session: MockSession
    let frozen: SessionSnapshot
    let completion: AsyncStream<LateCallCompletion>
    let buffer: OrphanFailureBuffer
    let immediateIssues: AsyncStream<MockIssue>
}

private let lateOwnerWork = AsyncStream<LateOwnerWork>.makeStream(bufferingPolicy: .bufferingNewest(1))

private func bridgeReleased(_ releasePath: String) -> Bool {
    guard let gate = FileHandle(forReadingAtPath: releasePath) else { return false }
    defer { try? gate.close() }
    return (try? gate.readToEnd()) == Data("release\n".utf8)
}

private func beginLateWork(
    context: ForeignCallContext,
    releasePath: String,
    ownerID: Test.ID,
    buffer: OrphanFailureBuffer,
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
            guard Test.current?.id == ownerID, Test.Case.current?.isParameterized == true else { return }
            // This task still carries the native context of the owner whose case ended.
            let batch = await FailureReporter.flushSwiftTestingOrphans(buffer)
            result.yield(.flushedFromInheritedCase(batch))
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
    let droppedOnly = environment["BLUEPRINT_CLOSED_OWNER_DROPPED_ONLY"] == "1"
    let buffer = droppedOnly ? OrphanFailureBuffer(maximumIssueBytes: 1) : OrphanFailureBuffer()
    let session = MockSession(orphanFailures: buffer)
    let (immediateIssues, immediateSink) = AsyncStream<MockIssue>.makeStream()
    let scope = TypeSubscriptDirectoryMock.makeTypeScope(
        failureReporter: FailureReporter { immediateSink.yield($0) }, session: session
    ) {
        $0.set_subscript(.equal(7), newValue: .equal(1)).willReturn(())
    }

    if scenario == "owner-A" {
        defer { lateOwnerWork.continuation.finish() }
        scope.withValue { TypeSubscriptDirectoryMock[7] = 1 }
        let frozen = try session.finishIfQuiescent()
        try #require(frozen.events.map(\.phase) == [.admitted, .returned])
        let completion = beginLateWork(
            context: context, releasePath: bridgePath + "/release", ownerID: nativeID, buffer: buffer
        ) {
            defer { immediateSink.finish() }
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
            nativeID: nativeID, session: session, frozen: frozen, completion: completion, buffer: buffer,
            immediateIssues: immediateIssues
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
        let batch: OrphanFailureBatch
        switch lateCall {
        case .queued:
            try #require(context != .inherited)
            // Flush while the peer is live without attributing the failures to that case.
            batch = await FailureReporter.flushSwiftTestingOrphans(owner.buffer)
        case .flushedFromInheritedCase(let inheritedBatch):
            try #require(context == .inherited)
            batch = inheritedBatch
        }
        if droppedOnly {
            try #require(batch.failures.isEmpty)
            try #require(batch.droppedCount == 1)
        } else {
            try #require(batch.failures.count == 1)
            try #require(batch.droppedCount == 0)
            let orphan = batch.failures[0]
            let ownerMock = try #require(owner.frozen.events.first?.mockID)
            try #require(orphan.epoch == owner.frozen.epoch)
            try #require(orphan.mockID == ownerMock)
            try #require(orphan.issue.kind == .unexpectedCall)
            try #require(orphan.issue.message.hasSuffix(" in a finished mock session"))
            print("BLUEPRINT_CLOSED_OWNER session=\(owner.session.id.rawValue.uuidString)"
                  + " epoch=\(orphan.epoch.rawValue) mock=\(ownerMock.rawValue) orphan=\(orphan.ordinal)")
        }

        let alreadyFlushed = await FailureReporter.flushSwiftTestingOrphans(owner.buffer)
        try #require(alreadyFlushed.failures.isEmpty)
        try #require(alreadyFlushed.droppedCount == 0)
        var ownerImmediate = owner.immediateIssues.makeAsyncIterator()
        try #require(await ownerImmediate.next() == nil)
        try #require(owner.session.snapshot() == owner.frozen)
        let peerOrphans = buffer.drain()
        try #require(peerOrphans.failures.isEmpty)
        try #require(peerOrphans.droppedCount == 0)
        immediateSink.finish()
        var peerImmediate = immediateIssues.makeAsyncIterator()
        try #require(await peerImmediate.next() == nil)
        try #require(baseline.events.map(\.phase) == [.admitted, .returned])
        try #require(session.snapshot() == baseline)
        try #require(Test.current?.id == nativeID)
        try #require(Test.Case.current?.isParameterized == true)
        print("PASS: DX023 owner closed while peer stayed active, one neutral issue")
    }
}
