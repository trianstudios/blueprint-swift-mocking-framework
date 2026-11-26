import ConsumerDoubles

func invalid(_ forwarding: inout VariadicDirectoryMock.VariadicForwarding) {
    forwarding.sample(Int.self) { _ in [] }
}
