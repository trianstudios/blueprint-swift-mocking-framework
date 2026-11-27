import ConsumerDoubles

struct UnhashableGenericMethodValue: Sendable {}

func invalidGenericMethodConstraint(_ mock: GenericMethodDirectoryMock) {
    _ = mock.transform(UnhashableGenericMethodValue())
}
