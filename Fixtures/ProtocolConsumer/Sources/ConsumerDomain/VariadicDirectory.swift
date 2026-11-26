public enum VariadicFailure: Error {
    case offline
}

public protocol VariadicDirectory: Sendable {
    func sample(_ entries: Int...) -> [Int]
    func names(in region: String, ids: Int..., fallback: String) async throws(VariadicFailure) -> String
}

public struct VariadicClient: Sendable {
    private let directory: any VariadicDirectory

    public init(directory: any VariadicDirectory) {
        self.directory = directory
    }

    public func emptySample() -> [Int] {
        directory.sample()
    }

    public func orderedSample() -> [Int] {
        directory.sample(7, 2, 7, 9)
    }

    public func largeSample() -> [Int] {
        directory.sample(
             0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
            16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
            32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
            48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63
        )
    }

    public func orderedNames() async throws(VariadicFailure) -> String {
        try await directory.names(in: "north", ids: 3, 1, 3, fallback: "default")
    }

    public func missingNames() async throws(VariadicFailure) -> String {
        try await directory.names(in: "offline", fallback: "default")
    }
}
