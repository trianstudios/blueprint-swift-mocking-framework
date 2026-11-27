import ConsumerDoubles

nonisolated func retainAutoclosure(
    _ stubs: LazyChoiceDirectoryMock.Stubs,
    retaining: @escaping @Sendable (@escaping () -> Int) -> Void
) {
    stubs.choose(id: .any).willAnswer { _, evaluate in
        retaining(evaluate)
        return -1
    }
}
