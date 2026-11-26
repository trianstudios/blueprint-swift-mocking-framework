public protocol AssociatedDirectory<Element>: AssociatedDirectoryBase {
    func save(_ value: Element)
}

public struct AssociatedDirectoryClient: Sendable {
    private let directory: any AssociatedDirectory<String>

    public init(directory: any AssociatedDirectory<String>) {
        self.directory = directory
    }

    public func refresh(key: String) -> String {
        let value = directory.load(key: key)
        directory.save(value)
        return value
    }
}
