public protocol AssociatedDirectoryBase<Element>: Sendable {
    associatedtype Element: Sendable

    func load(key: String) -> Element
    func discard(_ value: Element)
}
