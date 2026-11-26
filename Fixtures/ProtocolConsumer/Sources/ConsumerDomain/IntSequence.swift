public protocol IntSequence: CursorSequence<Swift.Int> {}

public func refreshIntSequence(_ sequence: any IntSequence) -> Int? {
    sequence.record(sequence.first())
    var iterator = sequence.makeIterator()
    return iterator.next()
}

public func firstFromCursorSequence<Source: CursorSequence>(_ sequence: Source) -> Source.Element? {
    var iterator = sequence.makeIterator()
    return iterator.next()
}
