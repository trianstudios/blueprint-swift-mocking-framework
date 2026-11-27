public protocol MixedRethrowingDirectory: Sendable {
    func apply(
        prefix: String, _ primary: (Int) throws -> String,
        fallback: (String) throws -> Int, offset: Int
    ) rethrows -> String

    func applyAsync(
        _ input: Int, using callback: @Sendable (Int) async throws -> String, prefix: String
    ) async rethrows -> String
}
