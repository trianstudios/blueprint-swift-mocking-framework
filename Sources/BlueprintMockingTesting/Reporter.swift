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
}
