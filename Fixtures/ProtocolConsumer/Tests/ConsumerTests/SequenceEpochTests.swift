import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

@Test(.timeLimit(.minutes(1)))
func RUN034_detachedMatchingCannotConsumeCurrentSequencePosition() async throws {
    let session = MockSession()
    let matcherEntered = AsyncStream<Bool>.makeStream()
    let releaseMatcher = DispatchSemaphore(value: 0)
    defer { releaseMatcher.signal() }

    let mock = UserRepositoryMock(
        failureReporter: .swiftTesting, session: session,
        failureMappings: .init { $0.fetchUser(id: String.self) { _ in .offline } }
    ) { stubs in
        // Hold the old call after admission, before it can reserve an answer.
        stubs.fetchUser(id: Matcher { id in
            guard id == "held" else { return true }
            matcherEntered.continuation.yield(true)
            return releaseMatcher.wait(timeout: .now() + .seconds(30)) == .success
        }).willSequence(
            .returning("first"), .returning("second"), .returning("third"), .returning("fourth"),
            policy: .finite
        )
    }
    let service = UserService(repository: mock)
    #expect(try await service.load(id: "prime") == "first")

    let held = Task.detached {
        defer { matcherEntered.continuation.finish() }
        return try await service.load(id: "held")
    }
    var entries = matcherEntered.stream.makeAsyncIterator()
    let entered = await entries.next()
    try #require(entered == true)

    let beforeReset = session.snapshot()
    #expect(beforeReset.activeInvocationCount == 1)
    #expect(beforeReset.events.map(\.phase) == [.admitted, .returned, .admitted])
    let heldAdmission = try #require(beforeReset.events.last)
    #expect(heldAdmission.phase == .admitted)

    #expect(throws: SessionResetError.activeInvocations(count: 1)) {
        try session.resetHistory()
    }
    #expect(session.snapshot() == beforeReset)

    let currentEpoch = try session.resetHistory(.detachActive)
    #expect(currentEpoch != beforeReset.epoch)
    #expect(session.snapshot().events.isEmpty)
    #expect(try await service.load(id: "current first") == "second")
    let beforeLateReturn = session.snapshot()
    #expect(beforeLateReturn.epoch == currentEpoch)
    #expect(beforeLateReturn.activeInvocationCount == 0)
    #expect(beforeLateReturn.events.map(\.phase) == [.admitted, .returned])
    #expect(beforeLateReturn.events.allSatisfy { $0.configurationRevision == heldAdmission.configurationRevision })
    #expect(mock.verify.fetchUser(id: .any).wasCalled(.once).passed)

    releaseMatcher.signal()
    let oldAnswer = try await held.value
    #expect(oldAnswer == "second")

    let archived = try #require(session.snapshot(epoch: beforeReset.epoch))
    let lateReturn = try #require(archived.events.last)
    #expect(archived.activeInvocationCount == 0)
    #expect(Array(archived.events.dropLast()) == beforeReset.events)
    #expect(lateReturn.phase == .returned)
    #expect(lateReturn.epoch == heldAdmission.epoch)
    #expect(lateReturn.invocationID == heldAdmission.invocationID)
    #expect(lateReturn.mockID == heldAdmission.mockID)
    #expect(lateReturn.endpoint == heldAdmission.endpoint)
    #expect(lateReturn.configurationRevision == heldAdmission.configurationRevision)

    let afterLateReturn = session.snapshot()
    #expect(afterLateReturn.epoch == currentEpoch)
    #expect(afterLateReturn.activeInvocationCount == 0)
    #expect(afterLateReturn.events == beforeLateReturn.events)
    #expect(afterLateReturn.watermark > beforeLateReturn.watermark)
    #expect(afterLateReturn.watermark == lateReturn.ordinal)
    #expect(mock.verify.fetchUser(id: .equal("held")).wasCalled(.never).passed)
    #expect(mock.verify.fetchUser(id: .any).wasCalled(.once).passed)

    let nextAnswer = try await service.load(id: "current second")
    #expect(nextAnswer == "third")
    #expect(mock.verify.fetchUser(id: .any, phase: .returned).wasCalled(.exactly(2)).passed)
}
