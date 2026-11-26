import BlueprintMocking
import BlueprintMockingTesting
import Testing

@Test func RUN032_projectedPublicConsumerProvesAStableLiteralArgument() async throws {
    let stubs = SyncStubbing<String, Int>()
    stubs.matching(.any).willAnswer { $0.count }
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("cachedReply"), configuration: stubs.finish(),
        projection: InvocationProjection(argument: { $0.lowercased() }, result: { $0 }),
        failureReporter: .swiftTesting
    )

    #expect(endpoint.invoke("SEAN") == 4)
    let result = try await endpoint.stable(.once, matchingArgument: "sean",
                                           for: .milliseconds(1), within: .seconds(1))
    #expect(result.observed == 1)
    #expect(result.epoch == endpoint.projectedHistory().epoch)
}
