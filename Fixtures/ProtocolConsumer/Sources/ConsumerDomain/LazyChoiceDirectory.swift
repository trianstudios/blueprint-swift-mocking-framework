public protocol LazyChoiceDirectory: Sendable {
    func choose(id: String, fallback value: @autoclosure () -> Int) -> Int
    func untouched(_ key: Int) -> Int
}
