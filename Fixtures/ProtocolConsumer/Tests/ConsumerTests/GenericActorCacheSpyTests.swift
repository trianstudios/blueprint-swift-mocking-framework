import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct CacheOverrides: GenericActorCacheMockBehavior {
    func lookup<Key: Hashable & Sendable>(_ key: Key) async -> GenericSpyDecision<String?> {
        switch key as? String {
        case "override": return .handled("override value")
        case "explicit miss": return .handled(nil)
        default: return .forward
        }
    }
}

private func load<Cache: GenericActorCache, Key: Hashable & Sendable>(
    from cache: Cache, key: Key
) async -> Cache.Value? {
    await cache.lookup(key)
}

@Test func SYS006_genericCacheSpyUsesBoundPolymorphismAndForwardsToActor() async throws {
    let session = MockSession()
    let real = IsolatedStringCache()
    await real.store("real override", for: "override")
    await real.store("real explicit miss", for: "explicit miss")
    await real.store("integer cache entry", for: 7)
    await real.store("boolean cache entry", for: true)
    let spy = GenericActorCacheMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, session: session,
        forwardingTo: real, genericBehavior: CacheOverrides()
    )
    let cache: any GenericActorCache<String> = spy

    let overridden = await load(from: spy, key: "override")
    let intentionallyMissing = await cache.lookup("explicit miss")
    let cachedInteger = await cache.lookup(7)
    let cachedBoolean = await load(from: spy, key: true)
    let absent = await cache.lookup("absent")
    #expect(overridden == "override value")
    #expect(intentionallyMissing == nil)
    #expect(cachedInteger == "integer cache entry")
    #expect(cachedBoolean == "boolean cache entry")
    #expect(absent == nil)
    #expect(await real.reads == ["Swift.Int:7", "Swift.Bool:true", "Swift.String:absent"])

    let snapshot = try session.finishIfQuiescent()
    #expect(snapshot.activeInvocationCount == 0)
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let terminals = snapshot.events.filter { $0.phase == .returned }
    #expect(snapshot.events.count == 10)
    #expect(admissions.map(\.invocationID) == terminals.map(\.invocationID))
    #expect(Set(admissions.map(\.invocationID)).count == 5)
    #expect(Set(admissions.map(\.mockID)).count == 1)
    #expect(Set(admissions.map(\.endpoint.rawValue)).count == 1)
    #expect(admissions.allSatisfy { $0.origin == nil })
    #expect(terminals.map(\.origin) == [nil, nil, .forwarded, .forwarded, .forwarded])
    #expect(terminals.map { $0.endpoint.specialization?.typeName }
        == ["Swift.String", "Swift.String", "Swift.Int", "Swift.Bool", "Swift.String"])
}
