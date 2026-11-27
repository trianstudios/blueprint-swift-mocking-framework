public protocol AsyncEscapingCallbackDirectory: Sendable {
    func register(id: String, using callback: @escaping @Sendable (Int) async -> String) -> String
}

public func registerAsyncEscapingCallback(
    _ directory: any AsyncEscapingCallbackDirectory,
    id: String,
    using callback: @escaping @Sendable (Int) async -> String
) -> String {
    directory.register(id: id, using: callback)
}
