import ConsumerDoubles

enum ForeignAdapterFailure: Error { case missing }

func invalid(_ forwarding: inout VariadicDirectoryMock.VariadicForwarding) {
    forwarding.names(in: String.self, ids: [Int].self, fallback: String.self) {
        (_, _, _) async throws(ForeignAdapterFailure) in
        throw .missing
    }
}
