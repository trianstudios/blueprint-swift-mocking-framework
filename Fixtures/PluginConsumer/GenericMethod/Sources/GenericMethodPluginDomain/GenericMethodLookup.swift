public protocol GenericMethodLookup: Sendable {
    func transform<Value: Hashable & Sendable>(_ value: Value) -> Value
    func auxiliary<Value: Hashable & Sendable>(_ value: Value) -> Value
}

public func transform<Value: Hashable & Sendable>(
    _ value: Value, using directory: any GenericMethodLookup
) -> Value {
    directory.transform(value)
}
