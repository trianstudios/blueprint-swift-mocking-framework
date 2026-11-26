@available(macOS 14.0, *)
public struct NewReceipt: Swift.Sendable {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }
}

public protocol AvailabilityDirectory: Swift.Sendable {
    func baseline() -> Int

    @available(macOS 14.0, *)
    func receipt() -> NewReceipt
}

public struct FloorAvailabilityDirectory: AvailabilityDirectory {
    public init() {}

    public func baseline() -> Int { 13 }

    @available(macOS 14.0, *)
    public func receipt() -> NewReceipt { NewReceipt(14) }
}

public func readAvailabilityBaseline(_ directory: any AvailabilityDirectory) -> Int {
    directory.baseline()
}

@available(macOS 14.0, *)
public func readAvailabilityReceipt(_ directory: any AvailabilityDirectory) -> NewReceipt {
    directory.receipt()
}
