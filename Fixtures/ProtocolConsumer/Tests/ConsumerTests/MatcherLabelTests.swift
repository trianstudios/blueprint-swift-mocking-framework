import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func RUN007_generatedSendableTupleVerificationReportsSourceLabels() {
    let reports = StoredProperty<[MockIssue]>([])
    let mock = LookupParametersMock(failureReporter: FailureReporter { issue in
        reports.set(reports.get() + [issue])
    }) { stubs in
        stubs.lookup(namespace: .any, .any).willReturn("found")
    }
    #expect(mock.lookup(namespace: "private-namespace", "private-key") == "found")

    let namespace = Matcher<String>.satisfying { _ in true }.named("known namespace")
    let key = Matcher<String>.equal("private-expected-key")
    #expect(!mock.verify.lookup(namespace: namespace, key).wasCalled(.once).passed)
    #expect(!mock.verify.lookup(namespace: .any, key).wasCalled(.once).passed)
    #expect(reports.get().map(\.message) == [
        "Expected exactly 1 calls; observed 0\nMatcher fields(namespace: known namespace, _: unnamed matcher)",
        "Expected exactly 1 calls; observed 0",
    ])
}

@MainActor
@Test func RUN007_generatedMainActorTupleVerificationReportsSourceLabels() {
    let reports = StoredProperty<[MockIssue]>([])
    let entry = DirectoryEntry("private-entry")
    let suffix = DirectoryEntry("private-suffix")
    let mock = MainActorDirectoryMock(failureReporter: FailureReporter { issue in
        reports.set(reports.get() + [issue])
    }) { stubs in
        stubs.merge(.any, with: .any).willReturn(entry)
    }
    #expect(mock.merge(entry, with: suffix) === entry)

    let otherEntry = MainActorMatcher<DirectoryEntry>.identical(to: DirectoryEntry("private-expected-entry"))
    let suffixCategory = MainActorMatcher<DirectoryEntry>.satisfying { _ in true }.named("suffix category")
    #expect(!mock.verify.merge(otherEntry, with: suffixCategory).wasCalled(.once).passed)
    #expect(!mock.verify.merge(otherEntry, with: .any).wasCalled(.once).passed)
    #expect(reports.get().map(\.message) == [
        "Expected exactly 1 calls; observed 0\nMatcher fields(_: unnamed matcher, with: suffix category)",
        "Expected exactly 1 calls; observed 0",
    ])
}
