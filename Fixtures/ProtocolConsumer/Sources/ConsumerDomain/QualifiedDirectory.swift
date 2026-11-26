import ParentDomain

public protocol SharedDirectory: ParentDomain.ForeignDirectoryLeaf, Sendable {
    func localLabel(for key: String) -> String
}

public protocol ForeignDirectoryLeaf: Sendable {
    func localDecoy() -> Int
}

public protocol QualifiedDirectory: ConsumerDomain.SharedDirectory, ParentDomain.SharedDirectory {
    func status() -> Int
}

public struct QualifiedDirectoryClient: Sendable {
    private let directory: any QualifiedDirectory

    public init(directory: any QualifiedDirectory) {
        self.directory = directory
    }

    public func labels(key: String, code: Int) -> (local: String, remote: String) {
        let local: any SharedDirectory = directory
        let remote: any ParentDomain.SharedDirectory = directory
        return (local.localLabel(for: key), remote.remoteLabel(for: code))
    }
}
