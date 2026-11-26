@MainActor public protocol ActorProfile: Sendable {
    func load(id: String) -> String
}
