import ConsumerDoubles

private nonisolated func keepExclusiveAccess(_ value: inout Swift.Int, during body: () -> Void) {
    body()
    value += 1
}

nonisolated func overlapsOrdinaryInoutWitness(_ mock: OrdinaryInoutDirectoryMock) {
    var value = 0
    keepExclusiveAccess(&value) {
        mock.normalize(&value)
    }
}
