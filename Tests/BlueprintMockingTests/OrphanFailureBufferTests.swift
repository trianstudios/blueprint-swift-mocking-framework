import Testing
@testable import BlueprintMocking

private func orphanSource(_ line: Int) -> BlueprintMocking.SourceLocation {
    SourceLocation(fileID: "ConsumerDomain/OwnedDirectory.swift", filePath: "OwnedDirectory.swift",
                   line: line, column: 4)
}

@Test func DX023_finishedCallQueuesForItsOwnerWithoutChangingFallbackOrHistory() throws {
    let buffer = OrphanFailureBuffer()
    let session = MockSession(orphanFailures: buffer)
    let scope = session.makeMock()
    let immediate = Issues()
    let member = EndpointID("owned-member")
    let setup = SyncStubbing<Int, Int>()
    setup.matching(.equal(1)).willReturn(7)
    let endpoint = SyncEndpoint(
        id: member, configuration: setup.finish(), failureReporter: immediate.reporter,
        scope: scope, fallback: { _ in -1 }
    )

    #expect(endpoint.invoke(1) == 7)
    #expect(endpoint.invoke(2, source: orphanSource(11)) == -1)
    #expect(immediate.values.map(\.source) == [orphanSource(11)])
    let before = buffer.drain()
    #expect(before.failures.isEmpty)
    #expect(before.droppedCount == 0)

    let final = try session.finishIfQuiescent()
    #expect(endpoint.invoke(1, source: orphanSource(12)) == -1)
    #expect(immediate.values.map(\.source) == [orphanSource(11)])
    #expect(session.snapshot() == final)
    #expect(endpoint.invocations.map(\.input) == [1, 2])

    let batch = buffer.drain()
    try #require(batch.failures.count == 1)
    let orphan = batch.failures[0]
    #expect(batch.droppedCount == 0)
    #expect(orphan.epoch == final.epoch)
    #expect(orphan.mockID == scope.id)
    #expect(orphan.issue.kind == .unexpectedCall)
    #expect(orphan.issue.endpoint == member)
    #expect(orphan.issue.source == orphanSource(12))
    #expect(orphan.issue.watermark == endpoint.invocations.last?.id)
    #expect(orphan.issue.message.hasSuffix(" in a finished mock session"))
    #expect(buffer.drain().failures.isEmpty)
}

@Test func DX023_staleScopeReportsLiveUntilFinishAndThenQueuesItsOriginalEpoch() throws {
    let buffer = OrphanFailureBuffer()
    let session = MockSession(clock: .manual, orphanFailures: buffer)
    let initialEpoch = session.snapshot().epoch
    let scope = session.makeEpochBoundMock()
    let immediate = Issues()
    let member = EndpointID("old-epoch-member")
    let endpoint = SyncEndpoint(
        id: member, configuration: SyncStubbing<Int, Int>().finish(), failureReporter: immediate.reporter,
        scope: scope, fallback: { _ in -1 }
    )
    let currentEpoch = try session.resetHistory()
    #expect(currentEpoch != initialEpoch)

    #expect(endpoint.invoke(1, source: orphanSource(21)) == -1)
    #expect(immediate.values.map(\.source) == [orphanSource(21)])
    #expect(immediate.values.first?.message.hasSuffix(" with a stale type-level mock scope") == true)
    #expect(buffer.drain().failures.isEmpty)
    let final = try session.finishIfQuiescent()

    #expect(endpoint.invoke(2, source: orphanSource(22)) == -1)
    #expect(immediate.values.map(\.source) == [orphanSource(21)])
    let batch = buffer.drain()
    try #require(batch.failures.count == 1)
    let orphan = batch.failures[0]
    #expect(batch.droppedCount == 0)
    #expect(orphan.epoch == initialEpoch)
    #expect(orphan.epoch != final.epoch)
    #expect(orphan.mockID == scope.id)
    #expect(orphan.issue.endpoint == member)
    #expect(orphan.issue.source == orphanSource(22))
    #expect(session.snapshot() == final)
    #expect(final.events.isEmpty)
}

@Test func DX023_orphanBufferCountsOverflowAndRetainsDistinctIdenticalFailures() throws {
    let buffer = OrphanFailureBuffer(capacity: 2)
    let session = MockSession(orphanFailures: buffer)
    let scope = session.makeMock()
    let immediate = Issues()
    let member = EndpointID("identical-orphans")
    let endpoint = SyncEndpoint(
        id: member, configuration: SyncStubbing<Int, Int>().finish(), failureReporter: immediate.reporter,
        scope: scope, fallback: { _ in -1 }
    )
    let final = try session.finishIfQuiescent()
    let identicalSource = orphanSource(31)
    for _ in 0..<2 {
        #expect(endpoint.invoke(0, source: identicalSource) == -1)
    }
    #expect(endpoint.invoke(0, source: orphanSource(32)) == -1)

    let full = buffer.drain()
    try #require(full.failures.count == 2)
    #expect(full.droppedCount == 1)
    let ordinals = full.failures.map(\.ordinal)
    #expect(ordinals[0] < ordinals[1])
    #expect(full.failures.allSatisfy {
        $0.mockID == scope.id && $0.epoch == final.epoch && $0.issue.endpoint == member
            && $0.issue.source == identicalSource && $0.issue.watermark == 0
    })
    #expect(full.failures[0].issue.message == full.failures[1].issue.message)
    let empty = buffer.drain()
    #expect(empty.failures.isEmpty)
    #expect(empty.droppedCount == 0)

    #expect(endpoint.invoke(0, source: identicalSource) == -1)
    let reused = buffer.drain()
    try #require(reused.failures.count == 1)
    #expect(reused.failures[0].ordinal > ordinals[1])
    #expect(reused.droppedCount == 0)
    #expect(immediate.values.isEmpty)
    #expect(session.snapshot() == final)
}

private func enqueueClosedCalls(_ lines: Range<Int>, endpoint: SyncEndpoint<Int, Int>) async {
    await withTaskGroup(of: Void.self) { group in
        for line in lines {
            group.addTask {
                #expect(endpoint.invoke(line, source: orphanSource(line)) == -1)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func DX023_concurrentOrphanDrainsClaimDisjointBatchesWhileMoreFailuresEnqueue() async throws {
    let buffer = OrphanFailureBuffer(capacity: 64)
    let session = MockSession(orphanFailures: buffer)
    let scope = session.makeMock()
    let immediate = Issues()
    let endpoint = SyncEndpoint(
        id: EndpointID("concurrent-orphans"), configuration: SyncStubbing<Int, Int>().finish(),
        failureReporter: immediate.reporter, scope: scope, fallback: { _ in -1 }
    )
    let final = try session.finishIfQuiescent()
    let firstWave = 100..<116
    let laterWave = 200..<216
    await enqueueClosedCalls(firstWave, endpoint: endpoint)

    let (claims, didClaim) = AsyncStream<Int>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    defer { release.finish() }
    let firstConsumer = Task {
        let batch = buffer.drain()
        didClaim.yield(batch.failures.count)
        didClaim.finish()
        var gate = releases.makeAsyncIterator()
        _ = await gate.next()
        return batch
    }
    var claimed = claims.makeAsyncIterator()
    try #require(await claimed.next() == firstWave.count)
    #expect(buffer.drain().failures.isEmpty)

    async let laterProducers: Void = enqueueClosedCalls(laterWave, endpoint: endpoint)
    async let secondConsumer = buffer.drain()
    async let thirdConsumer = buffer.drain()
    let (_, second, third) = await (laterProducers, secondConsumer, thirdConsumer)
    let residual = buffer.drain()
    let laterFailures = second.failures + third.failures + residual.failures
    #expect(laterFailures.map(\.issue.source.line).sorted() == Array(laterWave))
    #expect(second.droppedCount == 0)
    #expect(third.droppedCount == 0)
    #expect(residual.droppedCount == 0)

    release.finish()
    let first = await firstConsumer.value
    #expect(first.failures.map(\.issue.source.line).sorted() == Array(firstWave))
    #expect(first.droppedCount == 0)
    let all = first.failures + laterFailures
    #expect(Set(all.map(\.ordinal)).count == firstWave.count + laterWave.count)
    #expect(all.allSatisfy { $0.mockID == scope.id && $0.epoch == final.epoch })
    #expect(buffer.drain().failures.isEmpty)
    #expect(immediate.values.isEmpty)
    #expect(session.snapshot() == final)
}

@Test func DX023_oversizedOrphanCountsAsDroppedAndPreservesTypedFailureMapping() throws {
    let buffer = OrphanFailureBuffer(capacity: 4, maximumIssueBytes: 256)
    let session = MockSession(orphanFailures: buffer)
    let immediate = Issues()
    let mappedSources = CriticalState<[BlueprintMocking.SourceLocation]>([])
    let endpoint = SyncThrowingEndpoint(
        id: EndpointID("bounded-orphan"), configuration: SyncThrowingStubbing<Int, Int, ServiceError>().finish(),
        failureReporter: immediate.reporter, scope: session.makeMock(),
        failureMapping: { issue in
            mappedSources.withLock { $0.append(issue.source) }
            return .offline
        }
    )
    let final = try session.finishIfQuiescent()
    let ordinary = orphanSource(41)
    let oversized = BlueprintMocking.SourceLocation(
        fileID: ordinary.fileID, filePath: String(repeating: "é", count: 128), line: 42, column: 4
    )
    #expect(throws: ServiceError.offline) { try endpoint.invoke(1, source: oversized) }
    #expect(throws: ServiceError.offline) { try endpoint.invoke(2, source: ordinary) }

    let batch = buffer.drain()
    #expect(batch.failures.map(\.issue.source) == [ordinary])
    #expect(batch.droppedCount == 1)
    let empty = buffer.drain()
    #expect(empty.failures.isEmpty)
    #expect(empty.droppedCount == 0)
    #expect(mappedSources.withLock { $0 } == [oversized, ordinary])
    #expect(immediate.values.isEmpty)
    #expect(session.snapshot() == final)
}
