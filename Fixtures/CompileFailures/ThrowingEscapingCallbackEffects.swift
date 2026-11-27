import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

func invalidNonthrowingReplay(
    _ capture: ThrowingEscapingCallbackCapture<Int, String, CallbackFixtureError>
) -> String {
    capture.invoke(1, onUnavailable: { .unavailable })
}

func invalidThrowingStub(_ stubs: ThrowingEscapingCallbackDirectoryMock.Stubs) {
    stubs.register(id: .any).willThrow(CallbackFixtureError.rejected(1))
}
