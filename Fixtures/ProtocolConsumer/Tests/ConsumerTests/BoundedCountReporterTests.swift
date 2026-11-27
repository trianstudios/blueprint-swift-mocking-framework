import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

@Test func DX027_nativeReporterReceivesABoundedVerificationMessage() {
    let label = String(repeating: "チェック🧪", count: 5_000)
    let matcher = Matcher<String>.any.named(label).and(.any.named("unreached tail"))
    let mock = LookupParametersMock(failureReporter: .swiftTesting) { _ in }

    withKnownIssue("Expected one bounded count failure from the native Blueprint reporter") {
        mock.verify.lookup(namespace: matcher, .any).wasCalled(.once)
    } matching: { issue in
        issue.comments.contains { comment in
            let rendered = comment.rawValue
            return rendered.hasPrefix("Expected exactly 1 calls; observed 0\nMatcher fields(namespace: and(")
                && rendered.hasSuffix("… [truncated]")
                && rendered.utf8.count <= 4_096
                && !rendered.contains("\u{FFFD}")
        }
    }
}
