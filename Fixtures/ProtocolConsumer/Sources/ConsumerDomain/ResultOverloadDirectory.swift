public protocol ResultOverloadDirectory: Sendable {
    func lookup(id: String) -> Int
    func lookup(id: String) -> String
}

public struct ResultOverloadClient: Sendable {
    private let directory: any ResultOverloadDirectory

    public init(directory: any ResultOverloadDirectory) {
        self.directory = directory
    }

    public func loadCount(id: String) -> Int {
        directory.lookup(id: id)
    }

    public func loadName(id: String) -> String {
        directory.lookup(id: id)
    }
}
