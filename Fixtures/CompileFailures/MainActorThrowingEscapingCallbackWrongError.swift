import ConsumerDoubles

private enum ForeignMainActorCallbackError: Error {
    case rejected
}

nonisolated func invalidCallbackError(_ mock: MainActorThrowingEscapingCallbackDirectoryMock) {
    let callback: @MainActor @Sendable (Int) throws(ForeignMainActorCallbackError) -> String = {
        _ throws(ForeignMainActorCallbackError) in
        throw .rejected
    }
    _ = mock.register(id: "wrong-error", using: callback)
}
