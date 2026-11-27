public enum MainActorCallbackFixtureError: Error, Equatable, Sendable {
    case rejected(Int)
    case unavailable
}

public protocol MainActorThrowingEscapingCallbackDirectory: Sendable {
    func register(
        id: String,
        using callback: @escaping @MainActor @Sendable (Int) throws(MainActorCallbackFixtureError) -> String
    ) -> String
}

public func registerMainActorThrowingEscapingCallback(
    _ directory: any MainActorThrowingEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @MainActor @Sendable (Int) throws(MainActorCallbackFixtureError) -> String
) -> String {
    directory.register(id: id, using: callback)
}
