import ConsumerDoubles

enum UnrelatedRethrowingProviderError: Error {
    case unsolicited
}

struct UnrelatedRethrowingProvider: RethrowingDirectoryMockRethrowsBehavior {
    func apply(_ callback: (Int) throws -> String) rethrows -> String {
        throw UnrelatedRethrowingProviderError.unsolicited
    }
}
