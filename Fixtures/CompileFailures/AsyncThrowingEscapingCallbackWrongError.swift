import ConsumerDoubles

private enum ForeignAsyncCallbackError: Error {
    case rejected
}

func invalidAsyncCallbackError(_ mock: AsyncThrowingEscapingCallbackDirectoryMock) {
    let callback: @Sendable (Int) async throws(ForeignAsyncCallbackError) -> String = {
        _ async throws(ForeignAsyncCallbackError) in
        throw .rejected
    }
    _ = mock.register(id: "wrong-error", using: callback)
}
