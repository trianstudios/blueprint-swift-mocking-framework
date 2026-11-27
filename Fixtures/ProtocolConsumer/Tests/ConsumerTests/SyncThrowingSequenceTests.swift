import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

@Test func RUN012_syncFiniteSequenceReportsExhaustionBeforeMappingAndNeverFallsThrough() throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let mock = SpyDirectoryMock(
        failureReporter: FailureReporter { issue in issues.set(issues.get() + [issue]) },
        session: session, forwardingTo: RealSpyDirectory(),
        failureMappings: .init { mappings in
            mappings.cached(id: String.self) { issue in
                #expect(issues.get().count == 1)
                #expect(issues.get().last?.kind == .sequenceExhausted)
                #expect(issues.get().last?.source == issue.source)
                #expect(session.snapshot().activeInvocationCount == 1)
                return .exhausted
            }
        }
    ) { stubs in
        stubs.cached(id: .equal("burst")).willReturn("earlier")
        stubs.cached(id: .equal("burst")).willSequence(
            .returning("first"), .throwing(.offline),
            .answering { id throws(SpyDirectoryFailure) in "answer:" + id }
        )
    }
    let client = SpyDirectoryClient(directory: mock)

    #expect(try client.cached(id: "burst") == "first")
    #expect(throws: SpyDirectoryFailure.offline) { try client.cached(id: "burst") }
    #expect(try client.cached(id: "burst") == "answer:burst")
    #expect(issues.get().isEmpty)
    #expect(throws: SpyDirectoryFailure.exhausted) { try client.cached(id: "burst") }
    #expect(try client.cached(id: "other") == "cache:real:other")

    #expect(issues.get().map(\.kind) == [.sequenceExhausted])
    #expect(issues.get().first?.source.fileID == "ConsumerDomain/SpyDirectory.swift")
    #expect(mock.verify.cached(id: .equal("burst"), phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.cached(id: .equal("burst"), phase: .threw).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.cached(id: .equal("burst"), phase: .returned, origin: .forwarded).wasCalled(.never).passed)
    #expect(mock.verify.cached(id: .equal("other"), phase: .returned, origin: .forwarded).wasCalled(.once).passed)
}

@Test func RUN012_syncRepeatLastAndCycleRemainExplicit() throws {
    let cases: [(StubSequencePolicy, [String])] = [
        (.repeatLast, ["one", "two", "two", "two"]),
        (.cycle, ["one", "two", "one", "two"]),
    ]
    for (policy, expected) in cases {
        let mock = SpyDirectoryMock(failureReporter: .swiftTesting) { stubs in
            stubs.cached(id: .any).willSequence(.returning("one"), .returning("two"), policy: policy)
        }
        let client = SpyDirectoryClient(directory: mock)
        let answers = try expected.map { _ in try client.cached(id: "same") }
        #expect(answers == expected)
    }
}

@Test(.timeLimit(.minutes(1)))
func RUN012_syncConcurrentReservationsDoNotReuseAStepWhenTheAnswerThrowsOnCancellation() async throws {
    let session = MockSession()
    let lastIssue = StoredProperty<MockIssue?>(nil)
    let entered = AsyncStream<Bool>.makeStream()
    let releaseAnswer = DispatchSemaphore(value: 0)
    defer { releaseAnswer.signal() }
    let mock = SpyDirectoryMock(
        failureReporter: FailureReporter { lastIssue.set($0) }, session: session,
        failureMappings: .init { $0.cached(id: String.self) { _ in .exhausted } }
    ) { stubs in
        stubs.cached(id: .any).willSequence(
            .answering { _ throws(SpyDirectoryFailure) in
                entered.continuation.yield(true)
                guard releaseAnswer.wait(timeout: .now() + .seconds(30)) == .success else {
                    Issue.record("The held synchronous answer was not released")
                    throw .offline
                }
                if Task.isCancelled { throw .offline }
                return "first"
            },
            .returning("second"), .returning("third")
        )
    }
    let client = SpyDirectoryClient(directory: mock)
    let held = Task.detached {
        defer { entered.continuation.finish() }
        return try client.cached(id: "held")
    }
    var entry = entered.stream.makeAsyncIterator()
    let didEnter = await entry.next()
    try #require(didEnter == true)
    #expect(session.snapshot().events.map(\.phase) == [.admitted])

    let concurrent = try await withThrowingTaskGroup(of: String.self) { group in
        for id in ["parallel one", "parallel two"] {
            group.addTask { try client.cached(id: id) }
        }
        var answers: [String] = []
        for try await value in group { answers.append(value) }
        return answers
    }
    #expect(concurrent.sorted() == ["second", "third"])
    #expect(session.snapshot().activeInvocationCount == 1)
    held.cancel()
    releaseAnswer.signal()
    await #expect(throws: SpyDirectoryFailure.offline) { try await held.value }
    #expect(lastIssue.get() == nil)
    #expect(throws: SpyDirectoryFailure.exhausted) { try client.cached(id: "next") }
    #expect(lastIssue.get()?.kind == .sequenceExhausted)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func RUN012_syncDetachedPreReservationKeepsItsEpochCursor(restarting: Bool) async throws {
    let session = MockSession()
    let entered = AsyncStream<Bool>.makeStream()
    let releaseMatcher = DispatchSemaphore(value: 0)
    defer { releaseMatcher.signal() }
    let mock = SpyDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.cached(id: Matcher { id in
            guard id == "held" else { return true }
            entered.continuation.yield(true)
            return releaseMatcher.wait(timeout: .now() + .seconds(30)) == .success
        }).willSequence(.returning("first"), .returning("second"), .returning("third"))
    }
    let client = SpyDirectoryClient(directory: mock)
    #expect(try client.cached(id: "prime") == "first")
    let held = Task.detached {
        defer { entered.continuation.finish() }
        return try client.cached(id: "held")
    }
    var entry = entered.stream.makeAsyncIterator()
    let didEnter = await entry.next()
    try #require(didEnter == true)
    let beforeReset = session.snapshot()
    #expect(beforeReset.activeInvocationCount == 1)
    #expect(throws: SessionResetError.activeInvocations(count: 1)) { try session.resetHistory() }

    let currentEpoch = if restarting {
        try session.resetHistoryAndSequences(.detachActive)
    } else {
        try session.resetHistory(.detachActive)
    }
    #expect(try client.cached(id: "current first") == (restarting ? "first" : "second"))
    let beforeLateReturn = session.snapshot()
    releaseMatcher.signal()
    #expect(try await held.value == "second")
    #expect(session.snapshot(epoch: beforeReset.epoch)?.events.last?.phase == .returned)
    #expect(session.snapshot().epoch == currentEpoch)
    #expect(session.snapshot().events == beforeLateReturn.events)
    #expect(mock.verify.cached(id: .equal("held")).wasCalled(.never).passed)
    #expect(try client.cached(id: "current next") == (restarting ? "second" : "third"))
}
