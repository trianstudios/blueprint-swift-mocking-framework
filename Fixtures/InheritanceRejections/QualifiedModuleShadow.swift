public enum ParentDomain {
    public protocol SharedDirectory: Sendable {
        func nestedOnly() -> Swift.String
    }
}
