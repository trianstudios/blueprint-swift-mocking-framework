import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private struct SampleArrayProvider: Sendable {
    func respond(to entries: [Int]) -> [Int] { entries }
}

@Test func GEN020_variadicWitnessCapturesEmptyOrderedAndLargeTypedArrays() {
    let session = MockSession()
    let samples = ArgumentCaptor<[Int]>(session: session)
    let provider = SampleArrayProvider()
    let mock = VariadicDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.sample(.any).capturing(into: samples, projecting: { $0 }).willAnswer { entries in
            provider.respond(to: entries)
        }
    }
    let client = VariadicClient(directory: mock)

    #expect(client.emptySample() == [])
    #expect(client.orderedSample() == [7, 2, 7, 9])
    let large = Array(0..<64)
    #expect(client.largeSample() == large)
    #expect(samples.captures.map(\.value) == [[], [7, 2, 7, 9], large])
    #expect(mock.verify.sample(.equal([]), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.sample(.equal([7, 2, 7, 9])).wasCalled(.once).passed)
    #expect(mock.verify.sample(.equal([2, 7, 7, 9])).wasCalled(.never).passed)
    #expect(mock.verify.sample(.equal(large), phase: .returned).wasCalled(.once).passed)
}

@Test func GEN020_variadicParameterPreservesFixedLabelsAroundATypedAsyncEffect() async throws {
    let session = MockSession()
    let ids = ArgumentCaptor<[Int]>(session: session)
    let mock = VariadicDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.names(in: .equal("north"), ids: .equal([3, 1, 3]), fallback: .equal("default"))
            .capturing(into: ids, projecting: { $0.1 })
            .willAnswer { arguments async throws(VariadicFailure) in
                await Task.yield()
                return arguments.0 + ":" + arguments.1.map(String.init).joined(separator: ",") + ":" + arguments.2
            }
        stubs.names(in: .equal("offline"), ids: .equal([]), fallback: .equal("default"))
            .capturing(into: ids, projecting: { $0.1 })
            .willThrow(.offline)
    }
    let client = VariadicClient(directory: mock)

    #expect(try await client.orderedNames() == "north:3,1,3:default")
    await #expect(throws: VariadicFailure.offline) { try await client.missingNames() }
    #expect(ids.captures.map(\.value) == [[3, 1, 3], []])
    #expect(mock.verify.names(in: .equal("north"), ids: .equal([3, 1, 3]), fallback: .equal("default"),
                              phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.names(in: .equal("offline"), ids: .equal([]), fallback: .equal("default"),
                              phase: .threw).wasCalled(.once).passed)
}

@Test func GEN020_variadicFailureMapperUsesPackedArgumentType() async {
    let mock = VariadicDirectoryMock(
        failureReporter: .swiftTesting,
        failureMappings: .init { mappings in
            mappings.names(in: String.self, ids: [Int].self, fallback: String.self) { issue in
                #expect(issue.kind == .unexpectedCall)
                #expect(issue.endpoint.rawValue.contains("names(in:String,ids:Int...,fallback:String)"))
                return .offline
            }
        }
    ) { _ in }
    let client = VariadicClient(directory: mock)

    await withKnownIssue("An unstubbed variadic call reports before returning its mapped typed error") {
        await #expect(throws: VariadicFailure.offline) { try await client.orderedNames() }
    }
    #expect(mock.verify.names(in: .equal("north"), ids: .equal([3, 1, 3]), fallback: .equal("default"),
                              phase: .threw).wasCalled(.once).passed)
}
