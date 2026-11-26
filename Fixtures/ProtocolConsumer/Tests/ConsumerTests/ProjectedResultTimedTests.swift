import BlueprintMocking
import BlueprintMockingTesting
import Testing

@Test func RUN032_projectedPublicConsumerProvesAStableLiteralResult() async throws {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { "cached " + $0 }
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("currentReply"), configuration: stubs.finish(),
        projection: InvocationProjection(argument: { $0.count }, result: { $0.lowercased() }),
        failureReporter: .swiftTesting
    )

    #expect(endpoint.invoke("ADA") == "cached ADA")
    let result = try await endpoint.stable(.once, matchingResult: "cached ada",
                                           for: .milliseconds(1), within: .seconds(1))
    #expect(result.observed == 1)
    #expect(result.epoch == endpoint.projectedHistory().epoch)
}
