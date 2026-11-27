public protocol GenericMethodDirectory: Sendable {
    func transform<T: Hashable & Sendable>(_ value: T) -> T
}

public struct GenericMethodClient: Sendable {
    private let directory: any GenericMethodDirectory

    public init(directory: any GenericMethodDirectory) {
        self.directory = directory
    }

    public func transform<T: Hashable & Sendable>(_ value: T) -> T {
        directory.transform(value)
    }
}
