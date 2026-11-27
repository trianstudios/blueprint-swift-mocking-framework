public protocol RethrowingDirectory: Sendable {
    func apply(_ callback: (Int) throws -> String) rethrows -> String
    func label(for value: String) -> String
}
