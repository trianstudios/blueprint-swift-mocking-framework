public protocol ActorEscapingCallbackDirectory: Sendable {
    func register(id: String, using callback: @escaping @MainActor @Sendable (Int) -> String) -> String
}

public func registerActorEscapingCallback(
    _ directory: any ActorEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @MainActor @Sendable (Int) -> String
) -> String {
    directory.register(id: id, using: callback)
}
