import Testing
@testable import BlueprintMocking

private func timedProjectedEndpoint(
    session: MockSession, argument: @escaping @Sendable (String) -> String = { $0 }
) -> ProjectedSyncEndpoint<String, String, String, Int> {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    return ProjectedSyncEndpoint(
        id: EndpointID("timedSearch"), configuration: stubs.finish(),
        projection: InvocationProjection(argument: argument, result: { $0.count }),
        failureReporter: FailureReporter { _ in }, scope: session.makeMock()
    )
}

@Test func RUN032_projectedPendingResetsTheCandidateAtItsActualPublicationTime() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = timedProjectedEndpoint(session: session) { input in
        try! session.advanceClock(by: .seconds(3))
        return input
    }
    let wait = try endpoint.prepareArgumentStability(.never, matchingArgument: "match",
                                                      for: .seconds(3), within: .seconds(8))

    try session.advanceClock(by: .seconds(1))
    _ = endpoint.invoke("other") // Admission at t1; projection publishes at t4.
    try session.advanceClock(by: .seconds(3))
    let response = try await wait.value()

    #expect(response.observed == 0)
    #expect(response.elapsed == .seconds(7))
}

@Test func RUN032_projectedPendingAtCutoffCannotLaterProveTheInterval() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = timedProjectedEndpoint(session: session) { input in
        try! session.advanceClock(by: .seconds(6))
        return input
    }
    let wait = try endpoint.prepareArgumentStability(.never, matchingArgument: "match",
                                                      for: .seconds(5), within: .seconds(5))

    try session.advanceClock(by: .seconds(1))
    _ = endpoint.invoke("other") // Projection at t7 was still pending at t5.
    await #expect(throws: ProjectedTimedObservationError.incompleteHistory) { try await wait.value() }
}

@Test func RUN032_projectedCompletedWindowWinsBeforeEqualTimePendingAdmission() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = timedProjectedEndpoint(session: session)
    _ = endpoint.invoke("match")
    let wait = try endpoint.prepareArgumentStability(.once, matchingArgument: "match",
                                                      for: .seconds(3), within: .seconds(3))

    try session.advanceClock(by: .seconds(3))
    _ = endpoint.invoke("match")
    let response = try await wait.value()
    #expect(response.observed == 1)
    #expect(response.elapsed == .seconds(3))
    #expect(response.watermark < session.snapshot().watermark)
}

@Test func RUN032_projectedStabilityRejectsResetAndCancelsItsObservation() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = timedProjectedEndpoint(session: session)
    let stale = try endpoint.prepareArgumentStability(.never, matchingArgument: "match",
                                                       for: .seconds(3), within: .seconds(3))
    _ = try session.resetHistory(.detachActive)
    await #expect(throws: SessionCheckpointError.staleEpoch) { try await stale.value() }

    let active = try endpoint.prepareArgumentStability(.never, matchingArgument: "match",
                                                        for: .seconds(3), within: .seconds(3))
    let task = Task { try await active.value() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(session.withLock { $0.observationCount } == 0)
}

private enum ProjectedTimedFailure: Error { case expected }

@Test func RUN032_projectedArgumentStabilityIncludesTypedThrowingAdmissions() async throws {
    let session = MockSession(clock: .manual)
    let stubs = AsyncThrowingStubbing<String, String, ProjectedTimedFailure>()
    stubs.matching(.any).willThrow(.expected)
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("typedTimedSearch"), configuration: stubs.finish(),
        projection: InvocationProjection(argument: { $0 }, result: { $0.count }),
        failureReporter: FailureReporter { _ in }, scope: session.makeMock()
    )
    do throws(ProjectedTimedFailure) {
        _ = try await endpoint.invoke("match")
        Issue.record("Expected the typed failure")
    } catch {
        #expect(error == .expected)
    }
    let prepared = try endpoint.prepareArgumentStability(.once, matchingArgument: "match",
                                                          for: .seconds(3), within: .seconds(3))
    try session.advanceClock(by: .seconds(3))
    let response = try await prepared.value()
    #expect(response.observed == 1)
    #expect(response.elapsed == .seconds(3))
}

@Test func RUN032_projectedOrdinalsReplayAsIntentionalMetadataGaps() throws {
    let session = MockSession(clock: .manual)
    let endpoint = timedProjectedEndpoint(session: session)
    let before = session.checkpoint()

    _ = endpoint.invoke("match")
    let replay = try session.replay(since: before)
    #expect(replay.events.map(\.ordinal) == [1, 3])
    #expect(replay.events.map(\.phase) == [.admitted, .returned])
    #expect(replay.checkpoint.watermark == 3)
    #expect(try session.replay(since: replay.checkpoint).events.isEmpty)
}

@Test func RUN032_projectedStabilityDoesNotProvePrunedHistory() async throws {
    let session = MockSession(clock: .manual)
    let endpoint = timedProjectedEndpoint(session: session)
    let wait = try endpoint.prepareArgumentStability(.once, matchingArgument: "match",
                                                      for: .seconds(3), within: .seconds(3))
    _ = endpoint.invoke("match")
    try session.discardEvents(through: session.checkpoint())
    try session.advanceClock(by: .seconds(3))
    await #expect(throws: SessionCheckpointError.historyUnavailable) { try await wait.value() }
}
