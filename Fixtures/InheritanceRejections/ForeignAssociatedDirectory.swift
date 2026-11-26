public protocol ForeignAssociatedDirectory<Element>: Swift.Sendable {
    associatedtype Element: Swift.Sendable

    func load() -> Element
}
