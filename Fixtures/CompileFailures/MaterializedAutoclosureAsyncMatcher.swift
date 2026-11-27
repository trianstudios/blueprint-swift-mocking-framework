import BlueprintMocking
import ConsumerDoubles

nonisolated func invalidAsyncMatcher(_ stubs: MaterializedChoiceDirectoryMock.Stubs) {
    stubs.choose(id: .any, fallback: .satisfying { value async in
        value == 1
    }).willReturn(1)
}
