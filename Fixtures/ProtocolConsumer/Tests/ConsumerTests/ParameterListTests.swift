import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN012_typedParametersAndZeroArgumentMethodExecuteThroughConsumer() {
    let mock = LookupParametersMock(failureReporter: .swiftTesting) { stubs in
        stubs.next().willReturn("team")
        stubs.lookup(namespace: .any, .any).willReturn("unmatched")
        stubs.lookup(namespace: .equal("team"), .equal("ada")).willAnswer { arguments in
            arguments.0 + "/" + arguments.1
        }
        stubs.lookup(namespace: .equal("team"), id: .any).willAnswer { arguments in
            LookupRecord(id: arguments.1, namespace: arguments.0)
        }
    }
    #expect(LookupClient(lookup: mock).label(for: "ada") == "team/ada")
    #expect(mock.lookup(namespace: "other", "ada") == "unmatched")
    #expect(mock.lookup(namespace: "team", id: 42) == LookupRecord(id: 42, namespace: "team"))
    #expect(mock.verify.next().wasCalled(.once).passed)
    #expect(mock.verify.lookup(namespace: .equal("team"), .equal("ada")).wasCalled(.once).passed)
    #expect(mock.verify.lookup(namespace: .equal("other"), .equal("ada")).wasCalled(.once).passed)
    #expect(mock.verify.lookup(namespace: .any, id: .equal(42)).wasCalled(.once).passed)
    #expect(mock.verify.lookup(namespace: .equal("ada"), .equal("team")).wasCalled(.never).passed)
}

@Test @MainActor func GEN012_MainActorMultipleParametersStayTypedOnTheActor() {
    let expected = DirectoryEntry("Ada")
    let suffix = DirectoryEntry("!")
    let mock = MainActorDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.merge(.identical(to: expected), with: .identical(to: suffix)).willAnswer { inputs in
            MainActor.preconditionIsolated()
            inputs.0.name += inputs.1.name
            return inputs.0
        }
    }
    let merged = mock.merge(expected, with: suffix)
    #expect(merged === expected)
    #expect(merged.name == "Ada!")
    #expect(mock.verify.merge(.identical(to: expected), with: .identical(to: suffix)).wasCalled(.once).passed)
}
