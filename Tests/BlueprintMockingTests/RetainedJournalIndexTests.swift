import Testing
@testable import BlueprintMocking

@Test func retainedJournalIndicesSurviveOutOfOrderCompletionAndEpochResets() throws {
    let session = MockSession(clock: .manual)
    let journal = Journal<String>(
        endpoint: EndpointID("retained-index"),
        reporter: FailureReporter { Issue.record("\($0.message)") },
        scope: session.makeMock()
    )
    let oldEpoch = session.snapshot().epoch
    let finished = try #require(journal.begin("finished"))
    let detached = try #require(journal.begin("detached"))
    journal.complete(finished, phase: .returned)

    let currentEpoch = try session.resetHistory(.detachActive)
    let first = try #require(journal.begin("first"))
    let second = try #require(journal.begin("second"))
    let checkpoint = session.checkpoint()
    try session.discardEvents(through: checkpoint)

    journal.update(second, replacing: "updated")
    journal.update(detached, replacing: "must not reach current history")
    journal.complete(detached, phase: .returned)
    journal.complete(second, phase: .threw)
    let intermediate = journal.snapshot()
    #expect(intermediate.epoch == currentEpoch)
    #expect(intermediate.calls.map(\.id) == [3, 4])
    #expect(intermediate.calls.map(\.input) == ["first", "updated"])
    #expect(intermediate.calls.map(\.phase) == [.admitted, .threw])
    #expect(intermediate.watermark == 4)

    journal.complete(first, phase: .returned)
    let archived = try #require(session.snapshot(epoch: oldEpoch))
    #expect(archived.events.map(\.phase) == [.admitted, .admitted, .returned, .returned])
    #expect(archived.events.last?.invocationID == detached.event.invocationID)
    #expect(archived.activeInvocationCount == 0)
    let current = session.snapshot()
    #expect(current.prunedThrough == checkpoint.watermark)
    #expect(current.events.map(\.invocationID) == [second.event.invocationID, first.event.invocationID])
    #expect(current.events.map(\.phase) == [.threw, .returned])
    #expect(current.activeInvocationCount == 0)
    #expect(journal.snapshot().calls.map(\.phase) == [.returned, .threw])

    _ = try session.resetHistory()
    let finalEpoch = try session.resetHistory()
    let final = try #require(journal.begin("after two more resets"))
    journal.complete(final, phase: .returned)
    let finalHistory = journal.snapshot()
    #expect(finalHistory.epoch == finalEpoch)
    #expect(finalHistory.calls.map(\.id) == [5])
    #expect(finalHistory.calls.map(\.phase) == [.returned])
    #expect(finalHistory.watermark == 5)
    #expect(session.snapshot(epoch: oldEpoch) == nil)
}
