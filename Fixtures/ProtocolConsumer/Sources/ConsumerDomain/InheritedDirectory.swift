public protocol InheritedDirectory: InheritedDirectoryReadBranch, InheritedDirectoryWriteBranch {
    func identify() -> String
}

public struct InheritedDirectoryClient: Sendable {
    private let directory: any InheritedDirectory

    public init(directory: any InheritedDirectory) {
        self.directory = directory
    }

    public func labels(for key: String) -> (read: String, write: String) {
        let reader: any InheritedDirectoryReadBranch = directory
        let writer: any InheritedDirectoryWriteBranch = directory
        return (reader.label(for: key), writer.label(for: key))
    }
}
