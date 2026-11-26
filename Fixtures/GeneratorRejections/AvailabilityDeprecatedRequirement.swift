public protocol AvailabilityDeprecatedRequirement: Swift.Sendable {
    @available(macOS, introduced: 14.0, deprecated: 15.0)
    func receipt() -> Int
}
