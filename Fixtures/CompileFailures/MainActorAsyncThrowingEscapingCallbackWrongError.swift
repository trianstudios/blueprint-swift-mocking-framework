import ConsumerDoubles

private enum ForeignMainActorAsyncCallbackError: Error {
    case rejected
}

nonisolated func invalidCallbackError(_ mock: MainActorAsyncThrowingEscapingCallbackDirectoryMock) {
    let callback: @MainActor @Sendable (Int) async throws(ForeignMainActorAsyncCallbackError) -> String = {
        _ async throws(ForeignMainActorAsyncCallbackError) in
        throw .rejected
    }
    _ = mock.register(id: "wrong-error", using: callback)
}
