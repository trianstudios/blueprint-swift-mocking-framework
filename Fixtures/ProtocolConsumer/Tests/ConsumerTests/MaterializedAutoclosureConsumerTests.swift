import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class MaterializationProbe {
    var evaluations = 0
    var matcherValues: [Int] = []
    var issues: [MockIssue] = []
}

@Test @MainActor func GEN018_materializedMatcherAndAnswerReuseOneValue() {
    let session = MockSession()
    let probe = MaterializationProbe()
    let mock = MaterializedChoiceDirectoryMock(failureReporter: FailureReporter { issue in
        Issue.record("\(issue.message)")
    }, session: session) { stubs in
        stubs.choose(id: .equal("lookup"), fallback: .satisfying { value in
            MainActor.assumeIsolated { probe.matcherValues.append(value) }
            return value == 1
        }).willAnswer { $0.value * 10 }
        stubs.choose(id: .equal("lookup"), fallback: .satisfying { value in
            MainActor.assumeIsolated { probe.matcherValues.append(value) }
            return value == 2
        }).willReturn(-1)
    }
    let dependency: any MaterializedChoiceDirectory = mock

    func makeValue() -> Int {
        probe.evaluations += 1
        let during = mock.verify.choose(id: .any, fallback: .equal(1)).wasCalled(.never)
        #expect(during.status == .incompleteHistory)
        #expect(during.pendingInvocationIDs.count == 1)
        #expect(during.captures.isEmpty)
        #expect(session.snapshot().activeInvocationCount == 1)
        return probe.evaluations
    }

    #expect(dependency.choose(id: "lookup", fallback: makeValue()) == 10)
    #expect(probe.evaluations == 1)
    #expect(probe.matcherValues == [1, 1])

    let result = mock.verify.choose(id: .equal("lookup"), fallback: .equal(1), phase: .returned)
        .wasCalled(.once)
    #expect(result.passed)
    #expect(result.captures.map(\.value.value) == [1])
    #expect(result.captures.map(\.value.input) == ["lookup"])
    #expect(probe.evaluations == 1)
}

@Test @MainActor func GEN018_finishedMaterializedEndpointDoesNotEvaluate() throws {
    let session = MockSession()
    let probe = MaterializationProbe()
    let mock = MaterializedChoiceDirectoryMock(failureReporter: FailureReporter { issue in
        MainActor.assumeIsolated { probe.issues.append(issue) }
    }, session: session) { stubs in
        stubs.record(fallback: .any).willReturn(())
    }
    let dependency: any MaterializedChoiceDirectory = mock
    let finished = try session.finishIfQuiescent()

    func makeValue() -> Int {
        probe.evaluations += 1
        return 1
    }

    dependency.record(fallback: makeValue())
    #expect(probe.evaluations == 0)
    #expect(probe.issues.count == 1)
    #expect(probe.issues.first?.message.contains("finished") == true)
    #expect(session.snapshot().watermark == finished.watermark)
    #expect(session.snapshot().events.isEmpty)
    #expect(mock.verify.record(fallback: .any).wasCalled(.never).passed)
}
