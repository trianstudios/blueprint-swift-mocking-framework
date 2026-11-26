import ParentDomain

public protocol AssociatedDirectoryFromDependency<Element>: ParentDomain.BoundParent {
    func save(_ value: Element)
}

public struct DependencyBoundDirectoryClient: Sendable {
    private let directory: any AssociatedDirectoryFromDependency<String>

    public init(directory: any AssociatedDirectoryFromDependency<String>) {
        self.directory = directory
    }

    public func refresh(key: String) -> String {
        let result = directory.load(key: key)
        directory.save(result)
        return result
    }
}
