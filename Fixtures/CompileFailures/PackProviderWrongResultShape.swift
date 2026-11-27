import ConsumerDoubles

struct WrongResultPackProvider: PackProviderDirectoryMockBehavior {
    func echo<each Element: Sendable>(_ values: repeat each Element) -> (repeat (each Element, Int)) {
        (repeat (each values, 0))
    }
}
