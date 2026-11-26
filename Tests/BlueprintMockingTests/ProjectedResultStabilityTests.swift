import Testing
@testable import BlueprintMocking

private func projectedResultEndpoint(
    session: MockSession, result: @escaping @Sendable (String) -> String = { $0 }
) -> ProjectedSyncEndpoint<String, String, Int, String> {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    return ProjectedSyncEndpoint(
        id: EndpointID("timedResult"), configuration: stubs.finish(),
        projection: InvocationProjection(argument: { $0.count }, result: result),
        failureReporter: FailureReporter { _ in }, scope: session.makeMock()
    )
}

@Test(arguments: [4, 6])
func RUN032_projectedResultAtOrAfterCutoffCannotSettlePriorPendingField(delay: Int) async throws {
    let session = MockSession(clock: .manual)
    let endpoint = projectedResultEndpoint(session: session) { value in
        try! session.advanceClock(by: .seconds(delay))
        return value
    }
    let wait = try endpoint.prepareResultStability(.never, matchingResult: "wanted",
                                                   for: .seconds(5), within: .seconds(5))
    try session.advanceClock(by: .seconds(1))
    _ = endpoint.invoke("other") // Terminal result publishes exactly at or after t5.
    await #expect(throws: ProjectedTimedObservationError.incompleteHistory) { try await wait.value() }
}

@Test func RUN032_projectedResultStartsAtTerminalStampWithoutAllocatingAnotherOrdinal() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = projectedResultEndpoint(session: session) { value in
        try! session.advanceClock(by: .seconds(2))
        return value
    }
    let wait = try endpoint.prepareResultStability(.once, matchingResult: "wanted",
                                                   for: .seconds(2), within: .seconds(5))
    try session.advanceClock(by: .seconds(1))
    _ = endpoint.invoke("wanted") // Admission t1; terminal publication t3.
    try session.advanceClock(by: .seconds(2))
    let response = try await wait.value()
    let events = session.snapshot().events

    #expect(events.map(\.ordinal) == [1, 2])
    #expect(events.map(\.elapsed) == [.seconds(1), .seconds(3)])
    #expect(response.watermark == events.last?.ordinal)
    #expect(response.observed == 1)
    #expect(response.elapsed == .seconds(5))
}

private enum TimedResultFailure: Error { case offline }

@Test func RUN032_projectedTypedThrowSettlesAsAKnownNonReturn() async throws {
    let session = MockSession(clock: .manual)
    let stubs = AsyncThrowingStubbing<String, String, TimedResultFailure>()
    stubs.matching(.any).willAnswer { _ async throws(TimedResultFailure) in
        try! session.advanceClock(by: .seconds(2))
        throw .offline
    }
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("timedThrow"), configuration: stubs.finish(),
        projection: InvocationProjection(argument: { $0.count }, result: { $0 }),
        failureReporter: FailureReporter { _ in }, scope: session.makeMock()
    )
    let wait = try endpoint.prepareResultStability(.never, matchingResult: "wanted",
                                                   for: .seconds(2), within: .seconds(5))
    try session.advanceClock(by: .seconds(1))
    do throws(TimedResultFailure) {
        _ = try await endpoint.invoke("request")
        Issue.record("Expected the typed failure")
    } catch {
        #expect(error == .offline)
    }
    try session.advanceClock(by: .seconds(2))
    let response = try await wait.value()

    #expect(response.observed == 0)
    #expect(response.elapsed == .seconds(5))
    #expect(session.snapshot().events.last?.phase == .threw)
    #expect(response.watermark == session.snapshot().events.last?.ordinal)
}

@Test func RUN032_projectedArchivedCompletionCannotSettleAResultInTheNewEpoch() async throws {
    let session = MockSession(clock: .manual)
    let oldEpoch = session.snapshot().epoch
    let endpoint = projectedResultEndpoint(session: session) { value in
        _ = try! session.resetHistory(.detachActive)
        return value
    }
    let stale = try endpoint.prepareResultStability(.once, matchingResult: "wanted",
                                                    for: .seconds(2), within: .seconds(3))
    _ = endpoint.invoke("wanted")
    await #expect(throws: SessionCheckpointError.staleEpoch) { try await stale.value() }

    let current = try endpoint.prepareResultStability(.never, matchingResult: "wanted",
                                                      for: .seconds(2), within: .seconds(2))
    try session.advanceClock(by: .seconds(2))
    let response = try await current.value()
    #expect(response.observed == 0)
    #expect(response.epoch != oldEpoch)
    #expect(session.snapshot(epoch: oldEpoch)?.events.map(\.phase) == [.admitted, .returned])
}
