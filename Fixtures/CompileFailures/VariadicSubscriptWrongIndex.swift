import ConsumerDoubles

func invalidSubscriptElement(_ mock: VariadicSubscriptDirectoryMock) {
    _ = mock[field: "title", 1, "not an integer"]
}
