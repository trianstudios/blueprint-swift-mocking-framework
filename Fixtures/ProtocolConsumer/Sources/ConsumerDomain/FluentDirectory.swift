public protocol FluentDirectory: Sendable {
    func next(id: String) -> Self
}

public func nextDirectory<Directory: FluentDirectory>(_ directory: Directory, id: String) -> Directory {
    directory.next(id: id)
}

public func nextErasedDirectory(_ directory: any FluentDirectory, id: String) -> any FluentDirectory {
    directory.next(id: id)
}
