import ConsumerDoubles

nonisolated func retainNonescapingCallback(
    _ stubs: ImmediateCallbackDirectoryMock.Stubs,
    retaining: @escaping @Sendable (@escaping (Int) -> String) -> Void
) {
    stubs.process(scope: .any, .any).willAnswer { _, callback in
        retaining(callback)
        return "unexpected"
    }
}
