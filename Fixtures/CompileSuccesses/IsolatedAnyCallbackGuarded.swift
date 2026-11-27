import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

func guardedReplay() async throws -> String? {
    guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return nil }
    let session = MockSession()
    let captor = IsolatedAnyEscapingCallbackCaptor<Int, String>(session: session)
    let mock = IsolatedAnyCallbackDirectoryMock(
        failureReporter: FailureReporter { issue in preconditionFailure(issue.message) },
        session: session
    ) { stubs in
        stubs.register(id: .equal("guarded")).capturingCallback(into: captor).willReturn(true)
    }
    let value: @isolated(any) @Sendable (Int) -> String = isolatedAnyWorkerCallback
    _ = mock.register(id: "guarded", using: value)
    return try await captor.captures.first?.invoke(1)
}
