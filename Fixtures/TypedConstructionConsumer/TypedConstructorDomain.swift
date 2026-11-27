public enum ConstructionFailure: Error, Equatable {
    case rejected(seed: Int)
}

public protocol TypedConstructionDirectory: Sendable {
    init(seed: Int) throws(ConstructionFailure)
    func label(_ value: Int) -> String
}

public func createTypedDirectory<Directory: TypedConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) throws(ConstructionFailure) -> Directory {
    try type.init(seed: seed)
}
