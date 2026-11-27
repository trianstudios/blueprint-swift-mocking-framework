public protocol OrdinaryThrowingConstructionDirectory: Sendable {
    init(seed: Int) throws
    func label(_ offset: Int) -> String
}

public func createOrdinaryThrowingDirectory<Directory: OrdinaryThrowingConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) throws -> Directory {
    try type.init(seed: seed)
}
