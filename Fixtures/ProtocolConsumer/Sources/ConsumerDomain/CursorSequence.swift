public protocol CursorSequence<Element>: Swift.Sendable {
    associatedtype Element: Swift.Sendable
    associatedtype Iterator: Swift.IteratorProtocol & Swift.Sendable where Iterator.Element == Element

    func makeIterator() -> Iterator
    func first() -> Element
    func record(_ element: Element)
}
