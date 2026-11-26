public protocol AvailabilityMultiplePlatforms: Swift.Sendable {
    @available(macOS 14.0, iOS 17.0, *)
    func receipt() -> Int
}
