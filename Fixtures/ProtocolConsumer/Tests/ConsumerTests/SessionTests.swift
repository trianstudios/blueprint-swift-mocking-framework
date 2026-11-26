import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

@Test func RUN036_generatedMocksShareOnlyTheirExplicitSession() async throws {
    let session = MockSession()
    let first = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willReturn("first")
    }
    let second = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willReturn("second")
    }
    let independent = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.greeting(for: .any).willReturn("independent")
    }
    #expect(first.greeting(for: "first call") == "first")
    #expect(second.greeting(for: "second call") == "second")
    let detachedAnswer = await Task.detached { independent.greeting(for: "detached call") }.value
    #expect(detachedAnswer == "independent")

    let events = session.snapshot().events
    try #require(events.count == 4)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events[0].mockID == events[1].mockID)
    #expect(events[2].mockID == events[3].mockID)
    #expect(events[0].mockID != events[2].mockID)
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
    #expect(events.allSatisfy { $0.endpoint == events[0].endpoint })
    #expect(zip(events, events.dropFirst()).allSatisfy { pair in pair.0.ordinal < pair.1.ordinal })
    #expect(first.verify.greeting(for: .equal("first call")).wasCalled(.once).passed)
    #expect(first.verify.greeting(for: .equal("second call")).wasCalled(.never).passed)
    #expect(second.verify.greeting(for: .equal("second call")).wasCalled(.once).passed)
}

@Test func DX026_generatedMockReportsLateCallWithoutChangingFinalHistory() throws {
    let session = MockSession()
    let mock = EffectDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.cachedName(id: .any).willReturn("admitted")
    }
    #expect(try mock.cachedName(id: "before") == "admitted")
    let finished = try session.finishIfQuiescent()

    withKnownIssue("A call to a finished session must report to its original test") {
        #expect(throws: UnexpectedInvocationError.self) {
            try mock.cachedName(id: "after")
        }
    }
    #expect(session.snapshot() == finished)
    #expect(mock.verify.cachedName(id: .equal("before")).wasCalled(.once).passed)
    #expect(mock.verify.cachedName(id: .equal("after")).wasCalled(.never).passed)
}

@Test(.timeLimit(.minutes(1)))
func RUN031_RUN032_generatedSelectorsDriveTimedMetadataAssertions() async throws {
    let session = MockSession()
    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willReturn("selected")
        stubs.greeting(.any).willReturn("other overload")
    }
    #expect(mock.greeting(for: "call") == "selected")
    #expect(mock.greeting("call") == "other overload")

    let snapshot = session.snapshot()
    let returned = snapshot.events.filter { $0.phase == .returned }
    try #require(returned.count == 2)
    #expect(returned[0].mockID == returned[1].mockID)
    #expect(returned[0].endpoint != returned[1].endpoint)
    let selector = SessionCallSelector(mockID: returned[0].mockID, endpoint: returned[0].endpoint)
    let window = Duration.milliseconds(5)

    do {
        _ = try await session.until(.never, for: selector, phase: .returned, for: window)
        Issue.record("Expected the interval to reject its initial metadata count")
    } catch SessionTimedObservationError.violated(let mismatch) {
        #expect(mismatch.observed == 1)
        #expect(mismatch.epoch == snapshot.epoch)
        #expect(mismatch.watermark == snapshot.watermark)
    }

    let stable = try await session.stable(.once, for: selector, phase: .returned, for: window, within: .seconds(1))
    #expect(stable.observed == 1)
    #expect(stable.epoch == snapshot.epoch)
    #expect(stable.watermark == snapshot.watermark)
    #expect(stable.elapsed >= window)
}

@Test func RUN027_RUN028_generatedCallsRemainInHistoryAfterConsumption() throws {
    let session = MockSession()
    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willAnswer { $0 }
    }
    let start = session.checkpoint()
    #expect(mock.greeting(for: "first") == "first")
    #expect(mock.greeting(for: "second") == "second")

    let admissions = session.snapshot().events.filter { $0.phase == .admitted }
    try #require(admissions.count == 2)
    let selector = SessionCallSelector(mockID: admissions[0].mockID, endpoint: admissions[0].endpoint)
    let domain = SessionInteractionDomain.mock(selector.mockID)
    let scope = session.consumptionScope(named: "generated greetings")

    let first = try session.consume(.earliest(1), for: selector, in: scope)
    #expect(first.invocationIDs == [admissions[0].invocationID])
    let incomplete = try session.verifyNoMoreInteractions(in: domain, consumptionScope: scope, since: start)
    #expect(!incomplete.passed)

    let remaining = try session.consume(.all, for: selector, in: scope)
    #expect(remaining.invocationIDs == [admissions[1].invocationID])
    let complete = try session.verifyNoMoreInteractions(in: domain, consumptionScope: scope, since: start)
    #expect(complete.passed)
    #expect(complete.watermark == remaining.watermark)

    let otherScope = session.consumptionScope(named: "independent consumer")
    let independent = try session.verifyNoMoreInteractions(in: domain, consumptionScope: otherScope, since: start)
    #expect(!independent.passed)
    let original = try session.verifyNoInteractions(in: domain, since: start)
    #expect(original.outcome == .interaction(admissions[0]))
    #expect(mock.verify.greeting(for: .equal("first")).wasCalled(.once).passed)
    #expect(mock.verify.greeting(for: .equal("second")).wasCalled(.once).passed)
}
