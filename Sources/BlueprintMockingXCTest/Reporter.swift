import BlueprintMocking
import XCTest

extension FailureReporter {
    /// Records each mock failure in the active XCTest context.
    public static var xctest: Self {
        Self { issue in
            let source = issue.source
            if let file = source.staticFilePath, let line = UInt(exactly: source.line), line > 0 {
                XCTFail(issue.message, file: file, line: line)
            } else {
                // XCTFail requires a static file path for native attribution.
                XCTFail("\(source.filePath):\(source.line): \(issue.message)")
            }
        }
    }
}

#if os(macOS)
func nativeXCTestIssue(_ issue: MockIssue, detailPrefix: String = "") -> XCTIssue {
    let source = issue.source
    let location = source.line > 0 && !source.filePath.isEmpty
        ? XCTSourceCodeLocation(filePath: source.filePath, lineNumber: source.line) : nil
    let detail = detailPrefix + "source=\(source.fileID) line=\(source.line) column=\(source.column)"
    return XCTIssue(
        type: .assertionFailure, compactDescription: issue.message, detailedDescription: detail,
        sourceCodeContext: XCTSourceCodeContext(location: location), associatedError: nil, attachments: []
    )
}
#endif
