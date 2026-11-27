import BlueprintMocking
import ConsumerDomain
import Foundation

private struct FailureCatalogDouble: DefaultCatalogDirectory {
    let endpoint: SyncEndpoint<String, DefaultCatalogProduct>

    func lookup(sku: String) -> DefaultCatalogProduct {
        endpoint.invoke(sku, source: SourceLocation(fileID: "ConsumerDomain/DefaultCatalogDirectory.swift",
                                                    filePath: "DefaultCatalogDirectory.swift", line: 14, column: 1))
    }
}

func verifyDefaultValueFailure(cyclic: Bool) {
    let empty = DefaultValueRegistry()
    let registry: DefaultValueRegistry
    if cyclic {
        registry = empty
            .registering(DefaultCatalogProduct.self) { context throws(DefaultValueResolutionError) in
                DefaultCatalogProduct(name: try context.require(DefaultCatalogRegion.self).name)
            }
            .registering(DefaultCatalogRegion.self) { context throws(DefaultValueResolutionError) in
                DefaultCatalogRegion(name: try context.require(DefaultCatalogProduct.self).name)
            }
    } else {
        registry = empty
    }
    let session = MockSession()
    let definition = SyncStubbing<String, DefaultCatalogProduct>().finish()
    let reporter = FailureReporter { issue in
        let history = session.snapshot()
        let events = history.events
        precondition(history.activeInvocationCount == 0)
        precondition(events.map(\.phase) == [.admitted, .terminated])
        precondition(events[0].invocationID == events[1].invocationID)
        precondition(events.allSatisfy { $0.endpoint == issue.endpoint })
        precondition(issue.kind == .unexpectedCall && issue.source.fileID == "ConsumerDomain/DefaultCatalogDirectory.swift")
        FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
    }
    let endpoint = SyncEndpoint(
        id: EndpointID("catalog.lookup"), configuration: definition, failureReporter: reporter,
        scope: session.makeMock(), defaultValues: registry
    )
    let reader = DefaultCatalogReader(directory: FailureCatalogDouble(endpoint: endpoint))
    _ = reader.product(for: "unmatched")
    fatalError("RUN017 MISSING DEFAULT RETURNED")
}
