public protocol AssociatedLookup<Element>: Sendable {
    associatedtype Element: Sendable

    func load(key: String) -> Element
    func save(_ value: Element)
}

public func refresh<Element>(directory: any AssociatedLookup<Element>, key: String) -> Element {
    let value = directory.load(key: key)
    directory.save(value)
    return value
}
