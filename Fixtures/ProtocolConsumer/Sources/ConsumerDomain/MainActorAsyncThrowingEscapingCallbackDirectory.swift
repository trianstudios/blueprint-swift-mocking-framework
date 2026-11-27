public enum MainActorAsyncCallbackFixtureError: Error, Equatable, Sendable {
    case rejected(Int)
    case unavailable(Int)
}

public protocol MainActorAsyncThrowingEscapingCallbackDirectory: Sendable {
    func register(
        id: String,
        using callback: @escaping @MainActor @Sendable (Int) async throws(MainActorAsyncCallbackFixtureError) -> String
    ) -> String
}

public func registerMainActorAsyncThrowingEscapingCallback(
    _ directory: any MainActorAsyncThrowingEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @MainActor @Sendable (Int) async throws(MainActorAsyncCallbackFixtureError) -> String
) -> String {
    directory.register(id: id, using: callback)
}
