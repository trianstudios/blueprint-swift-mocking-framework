public protocol ForeignDirectoryLeaf: Sendable {
    func recordForeign(_ note: Swift.String)
}

public protocol SharedDirectory: ForeignDirectoryLeaf {
    func remoteLabel(for code: Swift.Int) -> Swift.String
}
