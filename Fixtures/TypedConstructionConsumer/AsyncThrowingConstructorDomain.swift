public enum AsyncConstructionFailure: Error, Equatable {
    case rejected(seed: Int)
    case interrupted(seed: Int)
}

public protocol AsyncThrowingConstructionDirectory: Sendable {
    init(seed: Int) async throws(AsyncConstructionFailure)
    func label(_ offset: Int) -> String
}

public func createAsyncThrowingDirectory<Directory: AsyncThrowingConstructionDirectory>(
    _ type: Directory.Type, seed: Int
) async throws(AsyncConstructionFailure) -> Directory {
    try await type.init(seed: seed)
}
