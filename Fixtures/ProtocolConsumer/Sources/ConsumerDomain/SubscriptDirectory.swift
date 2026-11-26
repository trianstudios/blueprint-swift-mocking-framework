public protocol SubscriptDirectory: Sendable {
    subscript(_ identifier: Int) -> String { get }
    subscript(_ key: String) -> String { get }
    subscript(row: Int, column: Int) -> String { get }
    subscript(_ row: Int, column column: String) -> String { get set }
    subscript() -> Int { get set }
    subscript(slot index: Bool) -> Int { get set }
}
