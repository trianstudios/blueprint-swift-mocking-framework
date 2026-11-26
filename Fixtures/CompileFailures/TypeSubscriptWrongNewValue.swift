import ConsumerDoubles

func invalidTypeSetter(_ stubs: TypeSubscriptDirectoryMock.TypeStubs) {
    _ = stubs.set_subscript(.any, newValue: .equal("not an Int"))
}
