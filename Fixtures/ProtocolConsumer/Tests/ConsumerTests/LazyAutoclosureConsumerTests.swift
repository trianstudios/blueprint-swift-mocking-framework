import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test @MainActor func GEN018_lazyAutoclosureEvaluatesOnlyOnExplicitAnswerRequests() {
    let session = MockSession()
    let mock = LazyChoiceDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.choose(id: .any).willReturn(-1)
        stubs.choose(id: .equal("single")).willAnswer { _, evaluate in evaluate() }
        stubs.choose(id: .equal("double")).willAnswer { _, evaluate in evaluate() * 100 + evaluate() }
        stubs.untouched(.any).willReturn(5)
    }
    let dependency: any LazyChoiceDirectory = mock
    var evaluations = 0
    func nextValue() -> Int {
        MainActor.preconditionIsolated()
        #expect(session.snapshot().activeInvocationCount == 1)
        evaluations += 1
        return evaluations
    }

    #expect(dependency.choose(id: "none", fallback: nextValue()) == -1)
    #expect(evaluations == 0)
    #expect(dependency.choose(id: "single", fallback: nextValue()) == 1)
    #expect(dependency.choose(id: "double", fallback: nextValue()) == 203)
    #expect(evaluations == 3)
    #expect(mock.verify.choose(id: .any, phase: .returned).wasCalled(.exactly(3)).passed)
    #expect(evaluations == 3)
    #expect(dependency.untouched(1) == 5)
}
