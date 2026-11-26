public protocol UntypedThrows: Sendable {
    func load(id: String) async throws -> String
}
