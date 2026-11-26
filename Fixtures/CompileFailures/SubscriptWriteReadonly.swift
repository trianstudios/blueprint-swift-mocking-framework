import ConsumerDoubles

func invalid(_ mock: EffectfulSubscriptDirectoryMock) {
    mock["row", region: 1] = "replacement"
}
