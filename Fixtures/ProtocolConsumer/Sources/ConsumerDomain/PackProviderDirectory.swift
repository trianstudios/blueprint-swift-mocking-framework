public protocol PackProviderDirectory: Sendable {
    func echo<each Element: Sendable>(_ values: repeat each Element) -> (repeat each Element)
    func label(for value: String) -> String
}
