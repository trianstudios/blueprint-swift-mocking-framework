import ConsumerDoubles

private nonisolated func keepExclusiveAccess(_ value: inout Swift.Int, during body: () -> Void) {
    body()
    value += 1
}

nonisolated func separatesOrdinaryInoutWitness(_ mock: OrdinaryInoutDirectoryMock) {
    var value = 0
    var independent = 0
    keepExclusiveAccess(&value) {
        mock.normalize(&independent)
    }
}
