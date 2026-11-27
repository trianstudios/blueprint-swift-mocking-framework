import ConsumerDoubles

private enum OtherEscapingCallbackError: Error {
    case rejected
}

func invalidCallbackError(_ mock: ThrowingEscapingCallbackDirectoryMock) {
    let callback: @Sendable (Int) throws(OtherEscapingCallbackError) -> String = {
        _ throws(OtherEscapingCallbackError) in
        throw .rejected
    }
    _ = mock.register(id: "wrong-error", using: callback)
}
