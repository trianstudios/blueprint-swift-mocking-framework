import BlueprintMocking
import ConsumerDomain
import Testing

private struct RelaxedCatalogDouble: DefaultCatalogDirectory {
    let endpoint: SyncEndpoint<String, DefaultCatalogProduct>

    func lookup(sku: String) -> DefaultCatalogProduct { endpoint.invoke(sku) }
}

@Test(.timeLimit(.minutes(1)))
func RUN017_checkedEndpointUsesRegisteredDomainDefaultAfterStubAndForwarding() throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let factorySnapshots = StoredProperty<[SessionSnapshot]>([])
    let registry = DefaultValueRegistry()
        .registering(DefaultCatalogRegion.self) { _ in DefaultCatalogRegion(name: "declared-region") }
        .registering(DefaultCatalogProduct.self) { context throws(DefaultValueResolutionError) in
            // Reentering session history proves the user factory runs outside runtime locks.
            factorySnapshots.set(factorySnapshots.get() + [session.snapshot()])
            let region = try context.require(DefaultCatalogRegion.self)
            return DefaultCatalogProduct(name: "registered/\(region.name)")
        }
    let setup = SyncStubbing<String, DefaultCatalogProduct>()
    setup.matching(.equal("present")).willReturn(DefaultCatalogProduct(name: "stubbed"))
    let plan = setup.finish()
    let reporter = FailureReporter { issues.set(issues.get() + [$0]) }
    let relaxed = SyncEndpoint(
        id: EndpointID("catalog.lookup"), configuration: plan, failureReporter: reporter,
        scope: session.makeMock(), defaultValues: registry
    )
    let forwarded = SyncEndpoint(
        id: EndpointID("catalog.forwarded"), configuration: plan, failureReporter: reporter,
        scope: session.makeMock(), forwarding: { DefaultCatalogProduct(name: "real/\($0)") },
        defaultValues: registry
    )
    let reader = DefaultCatalogReader(directory: RelaxedCatalogDouble(endpoint: relaxed))
    let forwardingReader = DefaultCatalogReader(directory: RelaxedCatalogDouble(endpoint: forwarded))

    #expect(reader.product(for: "present") == DefaultCatalogProduct(name: "stubbed"))
    #expect(forwardingReader.product(for: "present") == DefaultCatalogProduct(name: "stubbed"))
    #expect(forwardingReader.product(for: "reachable") == DefaultCatalogProduct(name: "real/reachable"))
    #expect(factorySnapshots.get().isEmpty)
    #expect(reader.product(for: "unmatched") == DefaultCatalogProduct(name: "registered/declared-region"))
    #expect(issues.get().isEmpty)

    let observed = factorySnapshots.get()
    try #require(observed.count == 1)
    #expect(observed[0].activeInvocationCount == 1)
    #expect(observed[0].events.last?.phase == .admitted)
    #expect(observed[0].events.last?.endpoint == EndpointID("catalog.lookup"))
    #expect(relaxed.verification(matching: .equal("unmatched"), phase: .returned).wasCalled(.once).passed)
    #expect(forwarded.verification(matching: .equal("reachable"), phase: .returned,
                                   origin: .forwarded).wasCalled(.once).passed)
    let finished = session.snapshot()
    #expect(finished.activeInvocationCount == 0)
    #expect(finished.events.map(\.phase) == [
        .admitted, .returned, .admitted, .returned, .admitted, .returned, .admitted, .returned,
    ])
    #expect(finished.events.last?.invocationID == observed[0].events.last?.invocationID)
}
