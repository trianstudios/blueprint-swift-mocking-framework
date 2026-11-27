public protocol MaterializedChoiceDirectory: Sendable {
    func choose(id: String, fallback value: @autoclosure () -> Int) -> Int
    func record(fallback value: @autoclosure () -> Int)
}
