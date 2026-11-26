public protocol ForeignAssociatedDirectory<Element>: Sendable {
    associatedtype Element: Sendable

    func load() -> Element
}
