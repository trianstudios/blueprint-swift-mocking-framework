public struct ParentDomain {
    public protocol SharedDirectory: Sendable {
        func selectiveOnly() -> Swift.String
    }
}
