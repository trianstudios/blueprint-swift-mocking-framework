import ConsumerDoubles

struct FixedArityPackProvider: PackProviderDirectoryMockBehavior {
    func echo<Element: Sendable>(_ value: Element) -> Element { value }
}
