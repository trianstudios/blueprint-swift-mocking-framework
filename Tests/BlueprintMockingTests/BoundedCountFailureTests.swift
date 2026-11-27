import Testing
@testable import BlueprintMocking

private final class DescriptionProbe: Sendable, CustomStringConvertible {
    private let evaluations = CriticalState(0)

    var descriptionCalls: Int { evaluations.withLock { $0 } }

    var description: String {
        evaluations.withLock { $0 += 1 }
        return "sensitive-payload-description"
    }
}

private let limit = 4_096
private let marker = "… [truncated]"
private let countLine = "Expected exactly 1 calls; observed 0"

private func expectBoundedIssue(_ issues: Issues, file: String, line: Int) throws {
    let issue = try #require(issues.values.first)
    #expect(issues.values.count == 1)
    #expect(issue.kind == .verificationFailed)
    #expect(issue.source.filePath == file)
    #expect(issue.source.line == line)
    #expect(issue.message.hasPrefix(countLine + "\nMatcher "))
    #expect(issue.message.hasSuffix(marker))
    #expect(issue.message.utf8.count <= limit)
    #expect(issue.message.utf8.count >= limit - 3)
    #expect(!issue.message.contains("\u{FFFD}"))
    #expect(!issue.message.contains("sensitive-payload-description"))
}

@Test func DX027_checkedVerificationBoundsTheFailureWithoutDescribingPayloads() throws {
    let issues = Issues()
    let payload = DescriptionProbe()
    let stubs = SyncStubbing<DescriptionProbe, Void>()
    stubs.matching(.any).willReturn(())
    let endpoint = SyncEndpoint(id: EndpointID("episode"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    endpoint.invoke(payload)

    let calls = CriticalState(0)
    let matcher = Matcher<DescriptionProbe> { _ in
        calls.withLock { $0 += 1 }
        return false
    }.named(String(repeating: "日本語🧪", count: 5_000))
    let result = endpoint.verification(matching: matcher, phase: .returned)
        .wasCalled(.once, fileID: "Probe/Client.swift", filePath: "Client.swift", line: 42)
    #expect(!result.passed)
    #expect(result.observed == 0)
    #expect(calls.withLock { $0 } == 1)
    #expect(payload.descriptionCalls == 0)
    try expectBoundedIssue(issues, file: "Client.swift", line: 42)
}

@Test @MainActor func DX027_mainActorVerificationUsesTheSameBoundedRenderer() throws {
    let issues = Issues()
    let payload = DescriptionProbe()
    let stubs = MainActorSyncStubbing<DescriptionProbe, Void>()
    stubs.matching(.any).willReturn(())
    let endpoint = MainActorSyncEndpoint(id: EndpointID("actor-episode"), configuration: stubs.finish(),
                                         failureReporter: issues.reporter)
    endpoint.invoke(payload)

    var calls = 0
    let matcher = MainActorMatcher<DescriptionProbe> { _ in
        calls += 1
        return false
    }.named(String(repeating: "actor🧪", count: 5_000)).and(.any.named("unreached tail"))
    let context = try #require(matcher.description)
    #expect(context.hasPrefix("and(actor"))
    #expect(context.hasSuffix(marker))
    #expect(context.utf8.count <= limit)
    let result = endpoint.verification(matching: matcher, phase: .returned)
        .wasCalled(.once, fileID: "Probe/ActorClient.swift", filePath: "ActorClient.swift", line: 50)
    #expect(!result.passed)
    #expect(result.observed == 0)
    #expect(calls == 1)
    #expect(payload.descriptionCalls == 0)
    try expectBoundedIssue(issues, file: "ActorClient.swift", line: 50)
}

@Test func DX027_renderingPreservesSmallAndExactlyBudgetedCountFailures() {
    let prefix = countLine + "\nMatcher "
    let label = String(repeating: "a", count: limit - prefix.utf8.count)
    #expect(MatcherDescription.countFailure(countLine, description: nil) == countLine)
    #expect(MatcherDescription.countFailure(countLine, description: "known account") == prefix + "known account")
    #expect(MatcherDescription.countFailure(countLine, description: label) == prefix + label)
    let clipped = MatcherDescription.countFailure(countLine, description: label + "🧪")
    #expect(clipped.utf8.count == limit)
    #expect(clipped.hasSuffix(marker))
    #expect(clipped == MatcherDescription.countFailure(countLine, description: label + "🧪"))
}
