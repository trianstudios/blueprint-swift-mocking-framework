public enum CallbackFixtureError: Error, Equatable, Sendable {
    case rejected(Int)
    case unavailable
}

public protocol ThrowingEscapingCallbackDirectory: Sendable {
    func register(id: String, using callback: @escaping @Sendable (Int) throws(CallbackFixtureError) -> String) -> String
}

public func registerThrowingEscapingCallback(
    _ directory: any ThrowingEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @Sendable (Int) throws(CallbackFixtureError) -> String
) -> String {
    directory.register(id: id, using: callback)
}
