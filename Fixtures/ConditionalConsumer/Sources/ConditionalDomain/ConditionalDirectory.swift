public protocol ConditionalDirectory: Swift.Sendable {
#if BLUEPRINT_DOMAIN_INT
    func value() -> Int
#else
    func value() -> String
#endif
}
