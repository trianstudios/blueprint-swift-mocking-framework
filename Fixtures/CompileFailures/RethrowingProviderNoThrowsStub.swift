import ConsumerDoubles

enum RethrowingStubError: Error {
    case unsolicited
}

nonisolated func cannotConfigureArbitraryApplyError(_ stubs: RethrowingDirectoryMock.Stubs) {
    stubs.apply().willThrow(RethrowingStubError.unsolicited)
}
