import BlueprintMocking

enum ForeignAsyncConstructionError: Error { case unavailable }

func configureWrongError() {
    _ = AsyncThrowingConstructionDirectoryMock.makeConstructionScope(failureReporter: FailureReporter { _ in }) {
        _, _ async throws(ForeignAsyncConstructionError) in throw .unavailable
    }
}
