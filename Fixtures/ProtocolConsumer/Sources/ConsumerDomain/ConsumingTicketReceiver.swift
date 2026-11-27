public final class OwnershipDestructionLog {
    public private(set) var destroyedIDs: [Int] = []

    public init() {}

    fileprivate func record(_ id: Int) {
        destroyedIDs.append(id)
    }
}

public struct OwnershipTicket: ~Copyable {
    private let id: Int
    private let log: OwnershipDestructionLog

    public init(id: Int, log: OwnershipDestructionLog) {
        self.id = id
        self.log = log
    }

    public borrowing func projectedID() -> Int { id }

    deinit { log.record(id) }
}

public protocol ConsumingTicketReceiver: Sendable {
    func receive(_ ticket: consuming OwnershipTicket) -> Int
    func status() -> String
}
