public protocol EscapingCallbackDirectory: Sendable {
    func register(id: String, using callback: @escaping @Sendable (Int) -> String) -> String
}

public func registerEscapingCallback(
    _ directory: any EscapingCallbackDirectory,
    id: String,
    using callback: @escaping @Sendable (Int) -> String
) -> String {
    directory.register(id: id, using: callback)
}
