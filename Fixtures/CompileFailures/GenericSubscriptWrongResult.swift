import ConsumerDoubles

func invalidGenericResult(_ stubs: GenericSubscriptDirectoryMock.Stubs) {
    let stub = stubs.get_subscript(.equal(7), as: Int.self)
    stub.willReturn("not an Int")
}
