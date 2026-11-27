public protocol RethrowingPairDirectory: Sendable {
    func apply(_ primary: (Int) throws -> String, fallback: (String) throws -> Int) rethrows -> String
}
