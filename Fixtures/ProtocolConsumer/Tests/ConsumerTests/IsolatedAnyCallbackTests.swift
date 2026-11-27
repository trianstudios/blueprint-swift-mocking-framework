import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private func detachedReplay(
    _ capture: IsolatedAnyEscapingCallbackCapture<Int, String>, _ value: Int
) async throws -> String {
    try await Task.detached { try await capture.invoke(value) }.value
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
@Test func GEN036_dynamicallyIsolatedCaptureReplaysOnOriginalActorsAfterRegistration() async throws {
    let session = MockSession()
    let captor = IsolatedAnyEscapingCallbackCaptor<Int, String>(session: session)
    let mock = IsolatedAnyCallbackDirectoryMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, session: session
    ) { stubs in
        stubs.register(id: .any).capturingCallback(into: captor).willReturn(true)
        stubs.register(id: .equal("ignored")).willReturn(false)
    }
    let directory: any IsolatedAnyCallbackDirectory = mock
    let main: @isolated(any) @Sendable (Int) -> String = isolatedAnyMainCallback
    let worker: @isolated(any) @Sendable (Int) -> String = isolatedAnyWorkerCallback
    #expect(main.isolation === MainActor.shared)
    #expect(worker.isolation === IsolatedAnyCallbackWorker.shared)

    #expect(directory.register(id: "main", using: main))
    #expect(directory.register(id: "worker", using: worker))
    #expect(!directory.register(id: "ignored", using: worker))
    let captures = captor.captures
    try #require(captures.count == 2)
    #expect(mock.verify.register(id: .equal("main"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.register(id: .equal("worker"), phase: .returned).wasCalled(.once).passed)
    let beforeReplay = session.snapshot()

    #expect(try await detachedReplay(captures[1], 5) == "worker:5")
    #expect(try await detachedReplay(captures[0], 2) == "main:2")
    #expect(try await detachedReplay(captures[1], 3) == "worker:8")
    let afterReplay = session.snapshot()
    #expect(afterReplay.events.map(\.ordinal) == beforeReplay.events.map(\.ordinal))
    #expect(afterReplay.activeInvocationCount == 0)

    _ = try session.resetHistory()
    #expect(captor.captures.isEmpty)
    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await captures[0].invoke(90)
    }
    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await captures[1].invoke(90)
    }

    #expect(directory.register(id: "new-epoch", using: worker))
    let fresh = try #require(captor.captures.first)
    #expect(fresh.invocation.epoch != captures[1].invocation.epoch)
    _ = try session.finishIfQuiescent()
    #expect(captor.captures.isEmpty)
    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await fresh.invoke(90)
    }
}
