import ConsumerDoubles

func invalidElement(_ mock: VariadicDirectoryMock) {
    _ = mock.sample(1, "not an integer")
}
