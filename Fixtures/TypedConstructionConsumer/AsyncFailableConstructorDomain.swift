public protocol AsyncFailableConstructionDirectory: Sendable {
    init?(seed: Int) async
    func label(_ offset: Int) -> String
}

public func createAsyncFailableDirectory<Directory: AsyncFailableConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) async -> Directory? {
    await type.init(seed: seed)
}
