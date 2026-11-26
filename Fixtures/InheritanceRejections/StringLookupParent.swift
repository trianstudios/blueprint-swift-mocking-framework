public protocol StringLookupParent: Sendable {
    func resolve(for key: Int) -> String
}
