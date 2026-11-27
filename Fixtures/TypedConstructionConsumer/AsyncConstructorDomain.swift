public protocol AsyncConstructionDirectory: Sendable {
    init(seed: Int) async
    func label(_ offset: Int) -> String
}

public func createAsyncDirectory<Directory: AsyncConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) async -> Directory {
    await type.init(seed: seed)
}
