import Testing
@testable import BlueprintMocking

private enum SequenceFixtureError: Error, Sendable {
    case scripted
    case exhausted
    case cancelled
}

@Test func RUN012_finiteSequencePreservesTypedEffectsAndDoesNotFallThrough() async throws {
    let issues = Issues()
    let session = MockSession()
    let source = SourceLocation(fileID: "Consumer/Sequence.swift", filePath: "Sequence.swift", line: 20)
    let setup = AsyncThrowingStubbing<Int, String, SequenceFixtureError>()
    setup.matching(.any).willReturn("broader rule")
    setup.matching(.equal(1)).willSequence(
        .returning("first"),
        .throwing(.scripted),
        .answering { input async throws(SequenceFixtureError) in "answer: \(input)" }
    )
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("finite"), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in
            #expect(session.snapshot().activeInvocationCount == 1)
            issues.reporter.report(issue)
        }, scope: session.makeMock(),
        failureMapping: { issue in
            #expect(issues.values.count == 1)
            #expect(issues.values.first?.kind == issue.kind)
            #expect(issue.source == source)
            return .exhausted
        }
    )

    #expect(try await endpoint.invoke(1) == "first")
    do {
        _ = try await endpoint.invoke(1)
        Issue.record("Expected the configured typed error")
    } catch {
        #expect(error == .scripted)
    }
    #expect(try await endpoint.invoke(1) == "answer: 1")
    #expect(issues.values.isEmpty)
    do {
        _ = try await endpoint.invoke(1, source: source)
        Issue.record("The exhausted sequence silently fell through to a lower-priority rule")
    } catch {
        #expect(error == .exhausted)
    }
    #expect(issues.values.map(\.kind) == [.sequenceExhausted])
    #expect(issues.values.first?.endpoint == EndpointID("finite"))
    #expect(endpoint.invocations.map(\.phase) == [.returned, .threw, .returned, .threw])
    #expect(try await endpoint.invoke(2) == "broader rule")
}

@Test func RUN012_explicitRepeatLastAndCycleFollowDifferentPolicies() async throws {
    let cases: [(StubSequencePolicy, [Int])] = [
        (.repeatLast, [10, 20, 20, 20, 20]),
        (.cycle, [10, 20, 10, 20, 10]),
    ]
    for (policy, expected) in cases {
        let issues = Issues()
        let setup = AsyncThrowingStubbing<String, Int, SequenceFixtureError>()
        setup.matching(.any).willSequence(.returning(10), .returning(20), policy: policy)
        let endpoint = AsyncThrowingEndpoint(
            id: EndpointID("repeat"), configuration: setup.finish(),
            failureReporter: issues.reporter, failureMapping: { _ in .exhausted }
        )
        var actual: [Int] = []
        for _ in expected {
            actual.append(try await endpoint.invoke("call"))
        }
        #expect(actual == expected)
        #expect(issues.values.isEmpty)
    }
}

@Test func RUN012_concurrentReservationsAreUniqueAndCancellationDoesNotReuseAStep() async throws {
    let issues = Issues()
    let entered = AsyncStream<Void>.makeStream()
    let holdAnswer = AsyncStream<Void>.makeStream()
    defer { holdAnswer.continuation.finish() }

    let setup = AsyncThrowingStubbing<String, Int, SequenceFixtureError>()
    setup.matching(.any).willSequence(
        .answering { _ async throws(SequenceFixtureError) in
            entered.continuation.finish()
            for await _ in holdAnswer.stream {}
            if Task.isCancelled { throw .cancelled }
            return 1
        },
        .returning(2),
        .returning(3)
    )
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("concurrent"), configuration: setup.finish(),
        failureReporter: issues.reporter, failureMapping: { _ in .exhausted }
    )
    let held = Task {
        defer { entered.continuation.finish() }
        return try await endpoint.invoke("held")
    }
    for await _ in entered.stream {}
    try #require(endpoint.invocations.first?.phase == .admitted)

    let outputs = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<2 {
            group.addTask { try await endpoint.invoke("concurrent") }
        }
        var results: [Int] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(outputs.sorted() == [2, 3])
    #expect(endpoint.invocations.first?.phase == .admitted)

    held.cancel()
    await #expect(throws: SequenceFixtureError.cancelled) { try await held.value }
    #expect(issues.values.isEmpty)
    await #expect(throws: SequenceFixtureError.exhausted) { try await endpoint.invoke("after cancellation") }
    #expect(issues.values.map(\.kind) == [.sequenceExhausted])
}

@Test func RUN012_reusingAPlanDoesNotShareCursorStateAcrossEndpointsOrRevisions() async throws {
    let issues = Issues()
    let setup = AsyncThrowingStubbing<String, Int, SequenceFixtureError>()
    setup.matching(.any).willSequence(.returning(1), .returning(2))
    let reusable = setup.finish()
    let first = AsyncThrowingEndpoint(id: EndpointID("first"), configuration: reusable,
                                      failureReporter: issues.reporter, failureMapping: { _ in .exhausted })
    let second = AsyncThrowingEndpoint(id: EndpointID("second"), configuration: reusable,
                                       failureReporter: issues.reporter, failureMapping: { _ in .exhausted })

    #expect(try await first.invoke("initial first") == 1)
    #expect(try await second.invoke("initial second") == 1)
    #expect(try await first.invoke("advance first") == 2)
    let replaced = first.replaceConfiguration(reusable)
    #expect(try await first.invoke("restart first") == 1)
    #expect(try await second.invoke("advance second") == 2)
    #expect(first.invocations.last?.configurationRevision == replaced)
    #expect(issues.values.isEmpty)
}

@Test func RUN012_suspendedAnswerKeepsItsOldReservationDuringLiveReplacement() async throws {
    let issues = Issues()
    let entered = AsyncStream<Void>.makeStream()
    let holdAnswer = AsyncStream<Void>.makeStream()
    defer { holdAnswer.continuation.finish() }

    let original = AsyncThrowingStubbing<String, Int, SequenceFixtureError>()
    original.matching(.any).willSequence(.answering { _ async throws(SequenceFixtureError) in
        entered.continuation.finish()
        for await _ in holdAnswer.stream {}
        return 1
    }, .returning(2))

    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("replacement"), configuration: original.finish(),
        failureReporter: issues.reporter, failureMapping: { _ in .exhausted }
    )
    let held = Task {
        defer { entered.continuation.finish() }
        return try await endpoint.invoke("old revision")
    }
    for await _ in entered.stream {}
    try #require(endpoint.invocations.first?.phase == .admitted)

    let replacement = AsyncThrowingStubbing<String, Int, SequenceFixtureError>()
    replacement.matching(.any).willSequence(.returning(100), .returning(101))
    let revision = endpoint.replaceConfiguration(replacement.finish())
    #expect(try await endpoint.invoke("new revision first") == 100)
    holdAnswer.continuation.finish()
    #expect(try await held.value == 1)
    #expect(try await endpoint.invoke("new revision second") == 101)
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [0, revision.rawValue, revision.rawValue])
    #expect(issues.values.isEmpty)
}
