import AsyncThrowingConstructorDomain

func missingAwait() async throws(AsyncConstructionFailure) -> AsyncThrowingConstructionDirectoryMock {
    try AsyncThrowingConstructionDirectoryMock(seed: 12)
}
