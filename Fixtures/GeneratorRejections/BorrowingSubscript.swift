public protocol BorrowingSubscript: Sendable {
    subscript(_ index: borrowing Int) -> String { get }
}
