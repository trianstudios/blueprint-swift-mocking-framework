import ConsumerDoubles

func invalidSubscriptArrayForwarding(_ mock: VariadicSubscriptDirectoryMock, collected: [Int]) {
    _ = mock[field: "title", collected]
}
