public protocol MissingParent: UnsuppliedParent, Sendable {
    func present() -> String
}
