public protocol Lookup: Sendable {
    func value(for key: String) -> String
}
