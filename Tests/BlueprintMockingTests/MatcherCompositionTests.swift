import Testing
@testable import BlueprintMocking

private final class ImmutableTag: Sendable, Equatable {
    let name: String
    init(_ name: String) { self.name = name }
    static func == (lhs: ImmutableTag, rhs: ImmutableTag) -> Bool { lhs.name == rhs.name }
}

private final class ActorLocalTag: Equatable {
    var name: String
    init(_ name: String) { self.name = name }
    static func == (lhs: ActorLocalTag, rhs: ActorLocalTag) -> Bool { lhs.name == rhs.name }
}

@Test func RUN006_sendableIdentityAndEqualitySelectDifferentStubs() {
    let issues = Issues()
    let expected = ImmutableTag("same value")
    let equalButSeparate = ImmutableTag("same value")
    let stubs = SyncStubbing<ImmutableTag, String>()
    stubs.matching(.equal(expected)).willReturn("equal")
    stubs.matching(.identical(to: expected)).willReturn("identical")
    let endpoint = SyncEndpoint(id: EndpointID("identity"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)

    #expect(endpoint.invoke(expected) == "identical")
    #expect(endpoint.invoke(equalButSeparate) == "equal")
    #expect(endpoint.verification(matching: .equal(expected)).wasCalled(.exactly(2)).passed)
    let identity = endpoint.verification(matching: .identical(to: expected)).wasCalled(.once)
    #expect(identity.passed)
    #expect(identity.invocationIDs == [1])
    #expect(issues.values.isEmpty)
}

@Test @MainActor func RUN006_mainActorIdentityAcceptsNonSendableReferences() {
    let issues = Issues()
    let expected = ActorLocalTag("same value")
    let equalButSeparate = ActorLocalTag("same value")
    let stubs = MainActorSyncStubbing<ActorLocalTag, String>()
    stubs.matching(.equal(expected)).willReturn("equal")
    stubs.matching(.identical(to: expected)).willReturn("identical")
    let endpoint = MainActorSyncEndpoint(id: EndpointID("actorIdentity"), configuration: stubs.finish(),
                                         failureReporter: issues.reporter)

    #expect(endpoint.invoke(expected) == "identical")
    #expect(endpoint.invoke(equalButSeparate) == "equal")
    #expect(endpoint.verification(matching: .identical(to: expected)).wasCalled(.once).passed)
    #expect(endpoint.verification(matching: .equal(expected)).wasCalled(.exactly(2)).passed)
    #expect(issues.values.isEmpty)
}

@Test func RUN006_optionalMatchersKeepOuterAndInnerAbsenceDistinct() {
    let outerNil = Matcher<Int??>.isNil()
    let innerNil = Matcher<Int??>.nonNil(.isNil())
    let anyOuterValue = Matcher<Int??>.nonNil()
    #expect(outerNil.matches(nil))
    #expect(!outerNil.matches(.some(nil)))
    #expect(!innerNil.matches(nil))
    #expect(innerNil.matches(.some(nil)))
    #expect(!innerNil.matches(.some(.some(2))))
    #expect(anyOuterValue.matches(.some(nil)))
    #expect(Matcher<Int?>.nonNil(.equal(2)).matches(2))
    #expect(!Matcher<Int?>.nonNil(.equal(2)).matches(3))
}

@Test @MainActor func RUN006_mainActorOptionalProjectionPreservesTypeAndIdentity() {
    let expected = ActorLocalTag("a")
    let equalButSeparate = ActorLocalTag("a")
    let identity = MainActorMatcher<ActorLocalTag?>.nonNil(.identical(to: expected))
    #expect(identity.matches(expected))
    #expect(!identity.matches(equalButSeparate))
    #expect(!identity.matches(nil))
    #expect(MainActorMatcher<ActorLocalTag?>.isNil().matches(nil))
    #expect(MainActorMatcher<ActorLocalTag?>.nonNil().matches(equalButSeparate))
}

@Test func RUN007_sendableMatchersShortCircuitLeftToRight() {
    let order = CriticalState<[String]>([])
    func probe(_ name: String, _ passed: Bool) -> Matcher<Int> {
        .satisfying { _ in
            order.withLock { $0.append(name) }
            return passed
        }
    }

    let yes = probe("yes", true)
    let no = probe("no", false)
    let skipped = probe("skipped", true)
    #expect(!yes.and(no).and(skipped).matches(1))
    #expect(no.or(yes).or(skipped).matches(1))
    #expect(!Matcher.allOf(yes, no, skipped).matches(1))
    #expect(Matcher.anyOf(no, yes, skipped).matches(1))
    #expect(yes.not().not().matches(1))
    #expect(Matcher<Int>.allOf().matches(1))
    #expect(!Matcher<Int>.anyOf().matches(1))
    #expect(order.withLock { $0 } == ["yes", "no", "no", "yes", "yes", "no", "no", "yes", "yes"])
}

@Test @MainActor func RUN007_mainActorMatchersShortCircuitWithActorLocalState() {
    let tag = ActorLocalTag("allowed")
    var order: [String] = []
    let check = MainActorMatcher<ActorLocalTag>.satisfying { input in
        order.append("check")
        return input.name == tag.name
    }
    let touches = MainActorMatcher<ActorLocalTag>.satisfying { _ in
        order.append("touches")
        return false
    }

    #expect(MainActorMatcher.anyOf(check, touches).matches(tag))
    #expect(check.or(touches).matches(tag))
    #expect(!MainActorMatcher.allOf(touches, check).matches(tag))
    #expect(!touches.and(check).matches(tag))
    #expect(touches.not().matches(tag))
    #expect(MainActorMatcher<ActorLocalTag>.allOf().matches(tag))
    #expect(!MainActorMatcher<ActorLocalTag>.anyOf().matches(tag))
    #expect(order == ["check", "check", "touches", "touches", "touches"])
}

@Test func RUN007_shortCircuitDoesNotChangeRulePrecedence() {
    let issues = Issues()
    let order = CriticalState<[String]>([])
    func probe(_ name: String, _ passed: Bool) -> Matcher<String> {
        .satisfying { _ in
            order.withLock { $0.append(name) }
            return passed
        }
    }

    let stubs = SyncStubbing<String, String>()
    stubs.matching(probe("older", true)).willReturn("older")
    stubs.matching(probe("newer", true).or(probe("unused", false))).willReturn("newer")
    stubs.matching(probe("rejected", false).and(probe("unused", true))).willReturn("unexpected")
    let endpoint = SyncEndpoint(id: EndpointID("precedence"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    #expect(endpoint.invoke("value") == "newer")
    #expect(order.withLock { $0 } == ["rejected", "newer"])
    #expect(issues.values.isEmpty)
}
