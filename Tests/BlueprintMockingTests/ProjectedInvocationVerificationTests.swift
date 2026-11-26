import Dispatch
import Testing
import BlueprintMocking

@Test func RUN009_projectedVerificationCapturesOnlySuccessfulMatchesInAdmissionOrder() async throws {
    let calls = AsyncStream<String>.makeStream()
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).willAnswer { $0 }
    let projection = InvocationProjection<String, String, String, Int>(
        argument: { input in
            calls.continuation.yield("argument")
            return String(input.prefix(1))
        },
        result: { output in
            calls.continuation.yield("result")
            return output.count
        }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("project"), configuration: setup.finish(), projection: projection,
        failureReporter: FailureReporter { _ in Issue.record("Unexpected runtime issue") }
    )
    for value in ["apple", "drum", "amber"] { _ = endpoint.invoke(value) }
    let history = endpoint.projectedHistory()
    let selected = history.calls.filter { $0.id == 1 || $0.id == 3 }

    let arguments = history.verify(.exactly(2), matchingArgument: .equal("a"))
    #expect(arguments.passed)
    #expect(arguments.status == .matched)
    #expect(arguments.observed == 2)
    #expect(arguments.captures.map(\.id) == [1, 3])
    #expect(arguments.captures.map(\.sessionInvocationID) == selected.map(\.sessionInvocationID))
    #expect(arguments.captures.map(\.value) == ["a", "a"])
    #expect(arguments.epoch == history.epoch)
    #expect(arguments.watermark == history.watermark)

    let results = history.verify(.exactly(2), matchingResult: .equal(5))
    #expect(results.status == .matched)
    #expect(results.captures.map(\.sessionInvocationID) == arguments.captures.map(\.sessionInvocationID))
    #expect(results.captures.map(\.value) == [5, 5])
    #expect(results.pendingInvocationIDs.isEmpty)
    #expect(results.unavailableInvocationIDs.isEmpty)
    #expect(history.verify(.exactly(2), matchingArgument: .equal("a")).captures.map(\.id) == [1, 3])

    let tooMany = history.verify(.once, matchingArgument: .equal("a"))
    #expect(!tooMany.passed)
    #expect(tooMany.status == .countMismatch)
    #expect(tooMany.observed == 2)
    #expect(tooMany.captures.isEmpty)
    let noResults = history.verify(.never, matchingResult: .equal(5))
    #expect(noResults.status == .countMismatch)
    #expect(noResults.captures.isEmpty)

    calls.continuation.finish()
    var observed: [String] = []
    for await call in calls.stream { observed.append(call) }
    #expect(observed == ["argument", "result", "argument", "result", "argument", "result"])
}

@Test func RUN009_contradictoryProjectedCountsDoNotEvaluateMatchersOrPublishCaptures() {
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).willAnswer { $0 }
    let projection = InvocationProjection<String, String, Int, Int>(
        argument: { $0.count }, result: { $0.count }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("contradictory"), configuration: setup.finish(), projection: projection,
        failureReporter: FailureReporter { _ in Issue.record("Unexpected runtime issue") }
    )
    _ = endpoint.invoke("value")
    let history = endpoint.projectedHistory()
    let impossible = CallCount.once.and(.never)
    let shouldNotRun = Matcher<Int>.satisfying { _ in
        Issue.record("Contradictory counts must not invoke user matching")
        return true
    }

    let argument = history.verify(impossible, matchingArgument: shouldNotRun)
    let result = history.verify(impossible, matchingResult: shouldNotRun)
    #expect(argument.status == .contradictoryCount)
    #expect(result.status == .contradictoryCount)
    #expect(!argument.passed && !result.passed)
    #expect(argument.observed == nil && result.observed == nil)
    #expect(argument.captures.isEmpty && result.captures.isEmpty)
}

@Test func RUN009_pendingFieldsAreAnIncompleteCaptureUntilPublished() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let returned = AsyncStream<String>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).willAnswer { $0 }
    let projection = InvocationProjection<String, String, Int, Int>(
        argument: { input in
            entered.continuation.finish()
            release.wait()
            return input.count
        },
        result: { $0.count }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("pending"), configuration: setup.finish(), projection: projection,
        failureReporter: FailureReporter { _ in Issue.record("Unexpected runtime issue") }
    )
    DispatchQueue.global().async {
        returned.continuation.yield(endpoint.invoke("value"))
        returned.continuation.finish()
    }

    for await _ in entered.stream {}
    let pending = endpoint.projectedHistory()
    let invocation = try #require(pending.calls.first?.sessionInvocationID)
    let shouldNotRun = Matcher<Int>.satisfying { _ in
        Issue.record("A pending field must not invoke user matching")
        return true
    }

    let pendingArgument = pending.verify(.never, matchingArgument: shouldNotRun)
    let pendingResult = pending.verify(.never, matchingResult: shouldNotRun, phase: .admitted)
    #expect(pendingArgument.status == .incompleteHistory)
    #expect(pendingResult.status == .incompleteHistory)
    #expect(pendingArgument.observed == 0 && pendingResult.observed == 0)
    #expect(pendingArgument.captures.isEmpty && pendingResult.captures.isEmpty)
    #expect(pendingArgument.pendingInvocationIDs == [invocation])
    #expect(pendingResult.pendingInvocationIDs == [invocation])
    #expect(pendingArgument.unavailableInvocationIDs.isEmpty)
    #expect(pendingResult.unavailableInvocationIDs.isEmpty)
    #expect(pending.verify(.never, matchingResult: shouldNotRun).passed)

    release.signal()
    var responses: [String] = []
    for await value in returned.stream { responses.append(value) }
    #expect(responses == ["value"])
    let completed = endpoint.projectedHistory()
    #expect(completed.verify(.once, matchingArgument: .equal(5)).captures.map(\.value) == [5])
    #expect(completed.verify(.once, matchingResult: .equal(5)).captures.map(\.value) == [5])
    #expect(pending.verify(.never, matchingArgument: .any).status == .incompleteHistory)
}
