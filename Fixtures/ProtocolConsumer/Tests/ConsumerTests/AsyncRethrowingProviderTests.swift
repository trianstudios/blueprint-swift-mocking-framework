import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct CallingAsyncRethrowingProvider: AsyncRethrowingDirectoryMockRethrowsBehavior {
    func apply(_ callback: @Sendable (Int) async throws -> String) async rethrows -> String {
        try await callback(19)
    }
}

private actor AsyncRethrowingAnswerGate {
    private let entries: AsyncStream<Int>.Continuation
    private var suspended: CheckedContinuation<Void, Never>?
    private var released = false

    init(entries: AsyncStream<Int>.Continuation) {
        self.entries = entries
    }

    func hold(_ input: Int) async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            suspended = continuation
            entries.yield(input)
        }
    }

    func release() {
        released = true
        let waiting = suspended
        suspended = nil
        waiting?.resume()
    }
}

private final class AsyncRethrowingCallbackError: Error {}

@Test(.timeLimit(.minutes(1)))
func GEN015_RUN005_generatedAsyncRethrowsKeepsSuspendedCallAndOriginalError() async throws {
    let session = MockSession()
    let entries = AsyncStream<Int>.makeStream()
    let gate = AsyncRethrowingAnswerGate(entries: entries.continuation)
    defer {
        entries.continuation.finish()
        Task { await gate.release() }
    }
    let mock = AsyncRethrowingDirectoryMock(
        failureReporter: .swiftTesting, session: session, rethrowsBehavior: CallingAsyncRethrowingProvider()
    )
    let directory: any AsyncRethrowingDirectory = mock
    let held = Task {
        defer { entries.continuation.finish() }
        return await directory.apply { input in
            await gate.hold(input)
            return "held-\(input)"
        }
    }
    var iterator = entries.stream.makeAsyncIterator()
    let input = await iterator.next()
    try #require(input == 19)

    let active = await Task.detached { session.snapshot() }.value
    try #require(active.events.count == 1)
    #expect(active.activeInvocationCount == 1)
    let firstAdmission = active.events[0]
    #expect(firstAdmission.phase == .admitted)

    let expected = AsyncRethrowingCallbackError()
    let throwingInputs = StoredProperty<[Int]>([])
    let throwing: @Sendable (Int) async throws(AsyncRethrowingCallbackError) -> String = {
        input async throws(AsyncRethrowingCallbackError) in
        throwingInputs.set(throwingInputs.get() + [input])
        throw expected
    }
    do {
        _ = try await directory.apply(throwing)
        Issue.record("Expected the original callback error")
    } catch {
        #expect((error as? AsyncRethrowingCallbackError) === expected)
    }
    #expect(throwingInputs.get() == [19])

    let whileHeld = session.snapshot()
    #expect(whileHeld.activeInvocationCount == 1)
    #expect(whileHeld.events.map(\.phase) == [.admitted, .admitted, .threw])
    #expect(whileHeld.events.first == firstAdmission)

    await gate.release()
    let returned = await held.value
    #expect(returned == "held-19")

    let settled = session.snapshot()
    let events = settled.events
    try #require(events.count == 4)
    #expect(settled.activeInvocationCount == 0)
    #expect(events.map(\.phase) == [.admitted, .admitted, .threw, .returned])
    #expect(events[0] == firstAdmission)
    #expect(events[0].invocationID == events[3].invocationID)
    #expect(events[1].invocationID == events[2].invocationID)
    #expect(events[0].invocationID != events[1].invocationID)
    let endpoint = firstAdmission.endpoint
    #expect(endpoint.rawValue.contains("ConsumerDomain.AsyncRethrowingDirectory|apply("))
    #expect(endpoint.rawValue.contains(" async rethrows"))
    #expect(events.allSatisfy {
        $0.endpoint == endpoint && $0.mockID == firstAdmission.mockID && $0.epoch == firstAdmission.epoch
    })
}
