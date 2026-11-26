public protocol IntLookupParent: Sendable {
    func resolve(for key: Int) -> Int
}
