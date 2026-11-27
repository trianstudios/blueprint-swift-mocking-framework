public enum AsyncCallbackFixtureError: Error, Equatable, Sendable {
    case rejected(Int)
    case unavailable(Int)
}

public protocol AsyncThrowingEscapingCallbackDirectory: Sendable {
    func register(
        id: String,
        using callback: @escaping @Sendable (Int) async throws(AsyncCallbackFixtureError) -> String
    ) -> String
}

public func registerAsyncThrowingEscapingCallback(
    _ directory: any AsyncThrowingEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @Sendable (Int) async throws(AsyncCallbackFixtureError) -> String
) -> String {
    directory.register(id: id, using: callback)
}
