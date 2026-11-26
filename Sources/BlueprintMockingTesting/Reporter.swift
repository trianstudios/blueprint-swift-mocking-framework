import BlueprintMocking
import Testing

extension FailureReporter {
    public static var swiftTesting: Self {
        Self { issue in
            Issue.record(Comment(rawValue: issue.message), sourceLocation: Testing.SourceLocation(
                fileID: issue.source.fileID, filePath: issue.source.filePath,
                line: issue.source.line, column: issue.source.column))
        }
    }

    /// Reports an orphaned issue to the active Swift Testing run and awaits its delivery.
    ///
    /// The diagnostic text preserves the original location. The native location points
    /// to this adapter so Swift Testing does not infer a test from the original location.
    public static func reportAtSwiftTestingRunLevel(_ issue: MockIssue) async {
        await Task.detached {
            let location = issue.source
            let original = "\(location.filePath):\(location.line):\(location.column)"
            Issue.record(Comment(rawValue: "\(original): \(issue.message)"))
        }.value
    }
}
