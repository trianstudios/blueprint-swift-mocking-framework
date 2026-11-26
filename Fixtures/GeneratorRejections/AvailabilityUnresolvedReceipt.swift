public protocol AvailabilityUnresolvedReceipt: Swift.Sendable {
    @available(macOS 14.0, *)
    func receipt() -> NewReceipt
}
