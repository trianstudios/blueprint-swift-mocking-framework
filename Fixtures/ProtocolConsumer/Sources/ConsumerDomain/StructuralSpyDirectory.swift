public enum StructuralSpyFailure: Error {
    case cycle
    case fixtureEscape
}

public protocol StructuralSpyDirectory: Sendable {
    func fetch(_ value: Int) async throws(StructuralSpyFailure) -> Int
}

public struct StructuralSpyClient: Sendable {
    private let directory: any StructuralSpyDirectory

    public init(directory: any StructuralSpyDirectory) {
        self.directory = directory
    }

    public func fetch(_ value: Int) async throws(StructuralSpyFailure) -> Int {
        try await directory.fetch(value)
    }
}
