import ConsumerDoubles

func cannotRetainScopeCallback(
    _ stubs: CallbackSpyDirectoryMock.Stubs,
    retaining: @escaping @Sendable (@escaping (Int) -> String) -> Void
) {
    stubs.transform(id: .any).willAnswer { id, callback in
        retaining(callback)
        return id
    }
}
