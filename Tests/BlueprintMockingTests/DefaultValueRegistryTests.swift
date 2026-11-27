import BlueprintMocking
import Testing

private struct DefaultTestRoot: Sendable, Equatable {
    let name: String
}

private struct DefaultTestLeaf: Sendable {
    let name: String
}

@Test func RUN017_registryResolvesExactTypedFactoriesAndKeepsPublishedCopiesIndependent() throws {
    let empty = DefaultValueRegistry()
    let registered = empty
        .registering(DefaultTestLeaf.self) { _ in DefaultTestLeaf(name: "child") }
        .registering(DefaultTestRoot.self) { context throws(DefaultValueResolutionError) in
            DefaultTestRoot(name: try context.require(DefaultTestLeaf.self).name)
        }
        .registering(Optional<DefaultTestRoot>.self) { _ in nil }
    let revised = registered.registering(DefaultTestLeaf.self) { _ in DefaultTestLeaf(name: "replacement") }

    #expect(throws: DefaultValueResolutionError.unregistered(typeName: String(reflecting: DefaultTestRoot.self))) {
        try empty.require(DefaultTestRoot.self)
    }
    #expect(try registered.require(DefaultTestRoot.self) == DefaultTestRoot(name: "child"))
    #expect(try revised.require(DefaultTestRoot.self) == DefaultTestRoot(name: "replacement"))
    #expect(try registered.require(DefaultTestRoot.self) == DefaultTestRoot(name: "child"))
    #expect(try registered.require(Optional<DefaultTestRoot>.self) == nil)
}

@Test func RUN017_registryRejectsCyclesAndDepthBeforeEnteringTheRepeatedFactory() throws {
    let rootName = String(reflecting: DefaultTestRoot.self)
    let leafName = String(reflecting: DefaultTestLeaf.self)
    let entered = StoredProperty<[String]>([])
    let cyclic = DefaultValueRegistry(maximumDepth: 4)
        .registering(DefaultTestRoot.self) { context throws(DefaultValueResolutionError) in
            entered.set(entered.get() + ["root"])
            return DefaultTestRoot(name: try context.require(DefaultTestLeaf.self).name)
        }
        .registering(DefaultTestLeaf.self) { context throws(DefaultValueResolutionError) in
            entered.set(entered.get() + ["leaf"])
            return DefaultTestLeaf(name: try context.require(DefaultTestRoot.self).name)
        }
    #expect(throws: DefaultValueResolutionError.cycle(typeNames: [rootName, leafName, rootName])) {
        try cyclic.require(DefaultTestRoot.self)
    }
    #expect(entered.get() == ["root", "leaf"])

    let shallow = DefaultValueRegistry(maximumDepth: 1)
        .registering(DefaultTestRoot.self) { context throws(DefaultValueResolutionError) in
            DefaultTestRoot(name: try context.require(DefaultTestLeaf.self).name)
        }
        .registering(DefaultTestLeaf.self) { _ in
            Issue.record("An out-of-depth factory executed")
            return DefaultTestLeaf(name: "unexpected")
        }
    #expect(throws: DefaultValueResolutionError.depthLimitExceeded(limit: 1, typeNames: [rootName, leafName])) {
        try shallow.require(DefaultTestRoot.self)
    }
}
