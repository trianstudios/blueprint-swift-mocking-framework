public protocol ConditionalDirectory: Swift.Sendable {
#if BLUEPRINT_DOMAIN_INT
    func value() -> Int
#else
    func value() -> String
#endif
#if !BLUEPRINT_DOMAIN_INT
    func inverted() -> Bool
#else
    func inverted() -> String
#endif
}
