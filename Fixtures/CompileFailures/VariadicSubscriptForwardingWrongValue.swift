import ConsumerDoubles

func invalid(_ forwarding: inout VariadicSubscriptDirectoryMock.VariadicForwarding) {
    forwarding.set_subscript(field: String.self, [Int].self, newValue: Int.self) { _, _, _ in }
}
