public protocol AsyncRethrowingDirectory: Sendable {
    func apply(_ callback: @Sendable (Int) async throws -> String) async rethrows -> String
}
