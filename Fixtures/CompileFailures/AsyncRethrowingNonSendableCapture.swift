import ConsumerDoubles

private final class NonSendableAsyncRethrowingPayload {
    var prefix = "local"
}

nonisolated func invalidAsyncRethrowingCapture(_ mock: AsyncRethrowingDirectoryMock) async -> String {
    let payload = NonSendableAsyncRethrowingPayload()
    return await mock.apply { @Sendable [payload] input in
        "\(payload.prefix)-\(input)"
    }
}
