public protocol AssociatedUnsupportedConstraint<Element>: Sendable {
    associatedtype Element: Hashable

    func load() -> Element
}
