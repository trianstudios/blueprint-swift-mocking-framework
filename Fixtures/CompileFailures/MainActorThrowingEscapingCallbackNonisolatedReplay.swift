import BlueprintMocking
import ConsumerDomain

nonisolated func invalidCallbackReplay(
    _ capture: MainActorThrowingEscapingCallbackCapture<Int, String, MainActorCallbackFixtureError>,
    onUnavailable: @MainActor () -> MainActorCallbackFixtureError
) throws(MainActorCallbackFixtureError) -> String {
    try capture.invoke(1, onUnavailable: onUnavailable)
}
