public protocol InheritanceCycleA: InheritanceCycleB, Sendable {
    func fromA()
}
