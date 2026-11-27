import BlueprintMocking

@globalActor
private actor ReplayFixtureActor {
    static let shared = ReplayFixtureActor()
}

nonisolated func invalidCallbackReplay(
    _ capture: MainActorAsyncEscapingCallbackCapture<Int, String>
) {
    let replay: @ReplayFixtureActor @Sendable (Int) async throws(CallbackDeliveryError) -> String =
        capture.invoke
    _ = replay
}
