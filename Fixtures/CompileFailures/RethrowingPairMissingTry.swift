import ConsumerDoubles

enum PairUnmarkedThrow: Error {
    case rejected
}

func invalidRethrowFromPrimary(_ mock: RethrowingPairDirectoryMock) -> String {
    mock.apply({ (_: Int) throws(PairUnmarkedThrow) -> String in
        throw .rejected
    }, fallback: { _ in 0 })
}

func invalidRethrowFromFallback(_ mock: RethrowingPairDirectoryMock) -> String {
    mock.apply({ _ in "primary" }, fallback: { (_: String) throws(PairUnmarkedThrow) -> Int in
        throw .rejected
    })
}
