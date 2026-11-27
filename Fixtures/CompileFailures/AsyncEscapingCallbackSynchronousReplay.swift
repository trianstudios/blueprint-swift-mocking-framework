import BlueprintMocking

nonisolated func invalidSynchronousReplay(
    _ capture: AsyncEscapingCallbackCapture<Int, String>
) throws(CallbackDeliveryError) -> String {
    try capture.invoke(1)
}
