public protocol BoundParent<Element>: Swift.Sendable {
    associatedtype Element: Swift.Sendable

    func load(key: Swift.String) -> Element
    func note(_ value: Element)
}
