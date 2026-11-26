import ConsumerDoubles

private final class NonSendableCallbackPayload {
    var prefix = "local"
}

nonisolated func invalidPayloadCapture(_ mock: EscapingCallbackDirectoryMock) {
    let payload = NonSendableCallbackPayload()
    _ = mock.register(id: "non-sendable", using: { @Sendable [payload] input in
        "\(payload.prefix)-\(input)"
    })
}
