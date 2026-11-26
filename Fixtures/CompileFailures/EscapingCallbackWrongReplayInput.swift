import BlueprintMocking

nonisolated func invalidReplayInput(_ callback: EscapingCallbackCapture<Int, String>) throws {
    _ = try callback.invoke("wrong input")
}
