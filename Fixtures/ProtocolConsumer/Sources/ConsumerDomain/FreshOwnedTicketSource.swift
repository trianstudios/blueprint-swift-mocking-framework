public struct FreshOwnedTicket: ~Copyable, Sendable {
    public let number: Int
    private let onDestroy: @Sendable (Int) -> Void

    public init(number: Int, onDestroy: @escaping @Sendable (Int) -> Void) {
        self.number = number
        self.onDestroy = onDestroy
    }

    deinit { onDestroy(number) }
}

public protocol FreshOwnedTicketSource: Sendable {
    func issue(_ key: Int) -> FreshOwnedTicket
    func complimentary() -> FreshOwnedTicket
    func status() -> String
}
