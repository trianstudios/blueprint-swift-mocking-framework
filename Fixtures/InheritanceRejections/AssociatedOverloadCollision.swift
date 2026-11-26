public protocol AssociatedOverloadCollision<Element>: Sendable {
    associatedtype Element: Sendable
    func put(_ value: Element)
    func put(_ value: String)
}
