public protocol UnsupportedEffect: Sendable {
    func load(id: String) rethrows -> String
}
