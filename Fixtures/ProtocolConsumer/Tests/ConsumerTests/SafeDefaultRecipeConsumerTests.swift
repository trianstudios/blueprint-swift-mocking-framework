import BlueprintMocking
import ConsumerDomain
import Testing

private struct SafeRecipeValueDirectory: ValueDirectory {
    let lookup: SyncEndpoint<[Int]?, [Int: LookupRecord]>
    let latest: SyncEndpoint<Void, LookupRecord?>

    func fetch(_ ids: [Int]?) -> [Int: LookupRecord] { lookup.invoke(ids) }
    func current() -> LookupRecord? { latest.invoke(()) }
}

@Test func RUN017_safeRecipesReturnTypedNilAndEmptyDictionaryThroughProtocol() throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let reporter = FailureReporter { issues.set(issues.get() + [$0]) }
    let defaults = DefaultValueRegistry.safePrimitives()
        .registeringNil(LookupRecord?.self)
        .registeringEmpty([Int: LookupRecord].self)

    let record = LookupRecord(id: 7, namespace: "stubbed")
    let setup = SyncStubbing<[Int]?, [Int: LookupRecord]>()
    setup.matching(.equal([7])).willReturn([7: record])
    let lookup = SyncEndpoint(
        id: EndpointID("safe.directory.fetch"), configuration: setup.finish(),
        failureReporter: reporter, scope: session.makeMock(), defaultValues: defaults
    )
    let latest = SyncEndpoint(
        id: EndpointID("safe.directory.current"),
        configuration: SyncStubbing<Void, LookupRecord?>().finish(),
        failureReporter: reporter, scope: session.makeMock(), defaultValues: defaults
    )
    let directory: any ValueDirectory = SafeRecipeValueDirectory(lookup: lookup, latest: latest)

    #expect(directory.fetch([7]) == [7: record])
    #expect(directory.fetch([99]).isEmpty)
    #expect(directory.current() == nil)
    #expect(throws: DefaultValueResolutionError.unregistered(typeName: String(reflecting: LookupRecord.self))) {
        try defaults.require(LookupRecord.self)
    }
    #expect(lookup.verification(matching: .equal([99]), phase: .returned).wasCalled(.once).passed)
    #expect(latest.verification(matching: .any, phase: .returned).wasCalled(.once).passed)
    #expect(issues.get().isEmpty)

    let history = session.snapshot()
    #expect(history.activeInvocationCount == 0)
    #expect(history.events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .returned])
    let admissions = history.events.filter { $0.phase == .admitted }
    let returns = history.events.filter { $0.phase == .returned }
    #expect(admissions.map(\.invocationID) == returns.map(\.invocationID))
}
