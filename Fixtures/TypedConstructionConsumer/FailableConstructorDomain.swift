public protocol FailableConstructionDirectory: Sendable {
    init?(seed: Int)
    func label(_ value: Int) -> String
}

public func createFailableDirectory<Directory: FailableConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) -> Directory? {
    type.init(seed: seed)
}
