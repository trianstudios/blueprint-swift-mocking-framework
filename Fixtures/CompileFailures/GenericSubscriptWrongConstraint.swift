import ConsumerDoubles

private struct UnhashableKey: Sendable {}

func invalidGenericConstraint(_ mock: GenericSubscriptDirectoryMock) {
    _ = mock[UnhashableKey()]
}
