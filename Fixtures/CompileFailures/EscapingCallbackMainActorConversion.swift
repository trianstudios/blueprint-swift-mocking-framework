import ConsumerDoubles

@MainActor
private func mainActorCallback(_ value: Int) -> String {
    String(value)
}

nonisolated func invalidActorCallback(_ mock: EscapingCallbackDirectoryMock) {
    _ = mock.register(id: "main-actor", using: mainActorCallback)
}
