import BlueprintMocking
import ConsumerDomain

@globalActor
private actor ThrowingReplayFixtureActor {
    static let shared = ThrowingReplayFixtureActor()
}

nonisolated func invalidCallbackReplay(
    _ capture: MainActorAsyncThrowingEscapingCallbackCapture<Int, String, MainActorAsyncCallbackFixtureError>
) {
    let replay: @ThrowingReplayFixtureActor @Sendable (
        Int, @MainActor @Sendable () -> MainActorAsyncCallbackFixtureError
    ) async throws(MainActorAsyncCallbackFixtureError) -> String = capture.invoke
    _ = replay
}
