import ConsumerDoubles

enum UnrelatedAsyncRethrowingProviderError: Error {
    case unsolicited
}

struct UnrelatedAsyncRethrowingProvider: AsyncRethrowingDirectoryMockRethrowsBehavior {
    func apply(_ callback: @Sendable (Int) async throws -> String) async rethrows -> String {
        throw UnrelatedAsyncRethrowingProviderError.unsolicited
    }
}
