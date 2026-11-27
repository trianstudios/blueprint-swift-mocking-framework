import ConsumerDoubles

private nonisolated func retainForLater(_ work: @escaping () -> Void) {}

nonisolated func cannotRetainOrdinaryInout(_ stubs: OrdinaryInoutDirectoryMock.Stubs) {
    stubs.normalize(.any).willAnswer { (value: inout Swift.Int) in
        retainForLater { value += 1 }
    }
}
