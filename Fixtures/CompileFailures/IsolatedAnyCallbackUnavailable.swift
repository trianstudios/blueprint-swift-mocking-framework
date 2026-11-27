import BlueprintMocking
import ConsumerDoubles

func cannotUseAtLowerDeployment(_ session: MockSession) {
    _ = IsolatedAnyEscapingCallbackCaptor<Int, String>(session: session)
    _ = IsolatedAnyCallbackDirectoryMock(
        failureReporter: FailureReporter { _ in },
        session: session
    ) { _ in }
}
