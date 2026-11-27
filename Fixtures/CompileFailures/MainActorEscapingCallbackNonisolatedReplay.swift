import BlueprintMocking

nonisolated func invalidCallbackReplay(
    _ capture: MainActorEscapingCallbackCapture<Int, String>
) throws(CallbackDeliveryError) -> String {
    try capture.invoke(1)
}
