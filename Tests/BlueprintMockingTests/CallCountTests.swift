import Testing
@testable import BlueprintMocking

@Test func RUN026_inclusiveRangeAndLogicalComposition() {
    let inclusive = CallCount.range(1, 3)
    #expect(!inclusive.accepts(0))
    #expect(inclusive.accepts(1))
    #expect(inclusive.accepts(3))
    #expect(!inclusive.accepts(4))
    #expect(CallCount.range(2...2).accepts(2))

    let count = CallCount.range(1...4)
        .or(.exactly(6))
        .and(CallCount.range(2...3).not())
    let actual = (0...7).filter(count.accepts)
    #expect(actual == [1, 4, 6])
}

@Test func RUN026_countAlgebraHandlesZeroAndMaximumWithoutOverflow() {
    let max = CallCount.exactly(Int.max)
    let belowMax = max.not()
    #expect(belowMax.accepts(0))
    #expect(belowMax.accepts(Int.max - 1))
    #expect(!belowMax.accepts(Int.max))
    #expect(!belowMax.accepts(-1))
    #expect(!belowMax.not().accepts(0))
    #expect(belowMax.not().accepts(Int.max))

    let all = CallCount.never.or(.atLeast(1))
    #expect(all.accepts(Int.max))
    #expect(!all.not().isSatisfiable)
    #expect(!CallCount.atMost(Int.max).not().isSatisfiable)
    #expect(CallCount.atLeast(Int.max).and(max).accepts(Int.max))
    #expect(max.not().or(max).accepts(Int.max))
}

@Test func RUN026_nestedCompositionMatchesFiniteReferenceModel() {
    let a = CallCount.range(1, 7).or(.range(9, 11))
    let b = CallCount.range(3, 5).or(.range(8, 10))
    let c = CallCount.exactly(10).or(.atLeast(13))
    let predicate = a.and(b).or(c).not().and(.range(0, 15))
    let observed = (0...16).filter(predicate.accepts)
    let expected = (0...16).filter { value in
        let aContains = (1...7).contains(value) || (9...11).contains(value)
        let bContains = (3...5).contains(value) || (8...10).contains(value)
        let cContains = value == 10 || value >= 13
        return !(aContains && bContains || cContains) && value <= 15
    }
    #expect(observed == expected)
}

@Test func RUN026_countDiagnosticsBoundLongDisjunctions() {
    let disjunction = stride(from: 2, through: 18, by: 2).reduce(CallCount.never) {
        $0.or(.exactly($1))
    }
    let message = disjunction.failureMessage(observed: 1)
    #expect(message == "Expected call count to match exactly 0 or exactly 2 or exactly 4 or 7 more ranges; observed 1")
    #expect(CallCount.once.and(.never).or(.exactly(5)).accepts(5))
}

@Test func RUN026_contradictionReportsReasonWithObservedEvidence() {
    let issues = Issues()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willReturn("ok")
    let endpoint = SyncEndpoint(id: EndpointID("count"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    _ = endpoint.invoke("argument")
    let impossible = CallCount.atLeast(3).and(.atMost(1))
    #expect(!impossible.isSatisfiable)

    let result = endpoint.verification(matching: .any).wasCalled(impossible, line: 99)
    #expect(!result.passed)
    #expect(result.observed == 1)
    #expect(result.watermark == 1)
    #expect(result.invocationIDs == [1])
    #expect(issues.values.count == 1)
    #expect(issues.values.first?.kind == .verificationFailed)
    #expect(issues.values.first?.source.line == 99)
    #expect(issues.values.first?.message.contains("Contradictory call-count predicate") == true)
    #expect(issues.values.first?.message.contains("at least 3") == true)
    #expect(issues.values.first?.message.contains("at most 1") == true)
}

@Test @MainActor func RUN026_mainActorReportsContradictoryCount() {
    let issues = Issues()
    let stubs = MainActorSyncStubbing<String, String>()
    let endpoint = MainActorSyncEndpoint(id: EndpointID("main-actor-count"),
                                        configuration: stubs.finish(), failureReporter: issues.reporter)
    let impossible = CallCount.atLeast(0).not()
    let result = endpoint.verification(matching: .any).wasCalled(impossible)
    #expect(!result.passed)
    #expect(result.observed == 0)
    #expect(issues.values.first?.message.contains("Contradictory call-count predicate") == true)
}

@Test func RUN026_compositionCountsOnlySelectedFailedInvocations() async {
    let issues = Issues()
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.equal("requested")).willThrow(.offline)
    stubs.matching(.equal("another-failure")).willThrow(.offline)
    stubs.matching(.equal("success")).willReturn("value")
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("load"), configuration: stubs.finish(),
                                         failureReporter: issues.reporter)

    for input in ["requested", "another-failure"] {
        do {
            _ = try await endpoint.invoke(input)
            Issue.record("Expected typed failure")
        } catch {
            #expect(error == .offline)
        }
    }
    do { #expect(try await endpoint.invoke("success") == "value") }
    catch { Issue.record("Unexpected failure: \(error)") }

    let completedFailures = endpoint.verification(matching: .any, phase: .threw)
        .wasCalled(.range(1...3).and(CallCount.once.not()))
    #expect(completedFailures.passed)
    #expect(completedFailures.invocationIDs == [1, 2])
    #expect(endpoint.verification(matching: .equal("requested"), phase: .threw)
        .wasCalled(.never.or(.once)).passed)
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(3)).passed)
    #expect(issues.values.isEmpty)
}
