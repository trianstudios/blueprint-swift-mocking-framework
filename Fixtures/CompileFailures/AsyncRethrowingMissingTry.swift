import ConsumerDoubles

enum AsyncRethrowingUnmarkedError: Error {
    case rejected
}

func invalidAsyncRethrowWithoutTry(_ mock: AsyncRethrowingDirectoryMock) async -> String {
    await mock.apply { @Sendable (_: Int) async throws(AsyncRethrowingUnmarkedError) -> String in
        throw .rejected
    }
}
