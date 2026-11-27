public protocol MainActorAsyncEscapingCallbackDirectory: Sendable {
    func register(id: String, using callback: @escaping @MainActor @Sendable (Int) async -> String) -> String
}

public func registerMainActorAsyncEscapingCallback(
    _ directory: any MainActorAsyncEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @MainActor @Sendable (Int) async -> String
) -> String {
    directory.register(id: id, using: callback)
}
