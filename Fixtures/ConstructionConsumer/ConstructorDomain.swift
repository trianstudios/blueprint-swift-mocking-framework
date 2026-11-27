public protocol ConstructionDirectory: Sendable {
    init(seed: Int)
    func label(_ value: Int) -> String
}

public func createDirectory<Directory: ConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) -> Directory {
    type.init(seed: seed)
}
