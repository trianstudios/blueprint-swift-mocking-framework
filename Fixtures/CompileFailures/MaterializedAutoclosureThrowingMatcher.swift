import BlueprintMocking
import ConsumerDoubles

private enum PredicateError: Error { case rejected }

nonisolated func invalidThrowingMatcher(_ stubs: MaterializedChoiceDirectoryMock.Stubs) {
    stubs.choose(id: .any, fallback: .satisfying { value throws -> Bool in
        if value < 0 { throw PredicateError.rejected }
        return value == 1
    }).willReturn(1)
}
