public protocol Lookup: Sendable {
    #if BLUEPRINT_DOMAIN_INT
    func lookup(key: String) -> Int
    #else
    func lookup(key: String) -> String
    #endif
}
