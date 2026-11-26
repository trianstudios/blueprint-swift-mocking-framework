import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private struct FrozenGeneratedResult: Equatable, Sendable {
    let value: String
}

@Test(.timeLimit(.minutes(1)))
func RUN009_generatedProjectionPreservesTypedEffectsAndDetachedHistory() async throws {
    let session = MockSession()
    let entered = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    defer { resume.continuation.finish() }
    let mock = GeneratedProjectionDirectoryProjectedMock(
        failureReporter: .swiftTesting,
        session: session,
        projection0: InvocationProjection(
            argument: { (input: GeneratedProjectionPayload) in input.snapshot() },
            result: { (output: GeneratedProjectionPayload) in output.snapshot() }),
        projection2: InvocationProjection(
            argument: { (input: GeneratedProjectionPayload) in input.snapshot() },
            result: { (output: GeneratedProjectionPayload) in FrozenGeneratedResult(value: output.snapshot()) })
    ) { stubs in
        stubs.read(id: .any).willAnswer { input in
            input.update("changed in read")
            return GeneratedProjectionPayload("read response", value: "read returned")
        }
        stubs.fetch(id: .any).willAnswer { input async throws(GeneratedProjectionFailure) in
            input.update("changed in fetch")
            if input.label == "pending" {
                entered.continuation.finish()
                for await _ in resume.stream {}
            }
            return GeneratedProjectionPayload(input.label, value: "returned " + input.label)
        }
        stubs.fetch(id: Matcher { $0.label == "offline" }).willThrow(.offline)
        stubs.ping().willReturn("pong")
    }
    let directory: any GeneratedProjectionDirectory = mock

    let readInput = GeneratedProjectionPayload("read", value: "before read")
    let readOutput = directory.read(id: readInput)
    readOutput.update("changed by caller")
    let read = try #require(mock.verify.history2.calls.first)
    #expect(read.phase == .returned)
    #expect(readInput.snapshot() == "changed in read")
    #expect(readOutput.snapshot() == "changed by caller")
    #expect(read.argument == .value("before read"))
    #expect(read.result == .value(FrozenGeneratedResult(value: "read returned")))
    #expect(mock.verify.history2.verify(.once, matchingArgument: .equal("before read")).passed)
    #expect(directory.ping() == "pong")
    #expect(mock.verify.ping().wasCalled(.once).passed)

    do throws(GeneratedProjectionFailure) {
        _ = try await directory.fetch(id: GeneratedProjectionPayload("offline", value: "before failure"))
        Issue.record("Expected the generated witness to throw the configured typed error")
    } catch {
        #expect(error == .offline)
    }
    let failed = try #require(mock.verify.history0.calls.first)
    #expect(failed.phase == .threw)
    #expect(failed.argument == .value("before failure"))
    #expect(failed.result == .unavailable)
    #expect(mock.verify.history0.verify(.once, matchingArgument: .equal("before failure"), phase: .threw).passed)

    let pendingInput = GeneratedProjectionPayload("pending", value: "before suspension")
    let old = Task { try await directory.fetch(id: pendingInput) }
    for await _ in entered.stream {}
    let beforeReset = mock.verify.history0
    let pending = try #require(beforeReset.calls.last)
    #expect(pending.phase == .admitted)
    #expect(pending.argument == .value("before suspension"))
    #expect(pending.result == .pending)
    #expect(pendingInput.snapshot() == "changed in fetch")

    let epoch = try session.resetHistory(.detachActive)
    #expect(epoch != pending.epoch)
    #expect(mock.verify.history0.calls.isEmpty)
    #expect(mock.verify.history2.calls.isEmpty)
    #expect(mock.verify.ping().wasCalled(.never).passed)

    let freshInput = GeneratedProjectionPayload("fresh", value: "before fresh fetch")
    let fresh = try await directory.fetch(id: freshInput)
    fresh.update("changed fresh output")
    resume.continuation.finish()
    let oldOutput = try await old.value
    #expect(oldOutput.snapshot() == "returned pending")

    let current = mock.verify.history0
    try #require(current.calls.count == 1)
    let retained = current.calls[0]
    #expect(current.epoch == epoch)
    #expect(retained.phase == .returned)
    #expect(retained.argument == .value("before fresh fetch"))
    #expect(retained.result == .value("returned fresh"))
    #expect(current.verify(.once, matchingResult: .equal("returned fresh")).passed)
    #expect(beforeReset.calls.last?.result == .pending)
    let archived = try #require(session.snapshot(epoch: pending.epoch))
    let oldEvents = archived.events.filter { $0.invocationID == pending.sessionInvocationID }
    #expect(oldEvents.map(\.phase) == [.admitted, .returned])
}
