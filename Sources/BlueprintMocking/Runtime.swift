// A compile-time generated-code/runtime schema marker. This is not a release version.
public enum BlueprintRuntimeSchemaV1 {}

public struct EndpointID: Sendable, Equatable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct SourceLocation: Sendable, Equatable {
    public let fileID: String
    public let filePath: String
    public let line: Int
    public let column: Int

    /// The original literal, when available for reporters that require a static path.
    public let staticFilePath: StaticString?

    public init(fileID: String = #fileID, filePath: String, line: Int = #line, column: Int = #column) {
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
        self.staticFilePath = nil
    }

    public init(fileID: String = #fileID, staticFilePath: StaticString = #filePath,
                line: Int = #line, column: Int = #column) {
        self.fileID = fileID
        self.filePath = staticFilePath.description
        self.line = line
        self.column = column
        self.staticFilePath = staticFilePath
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fileID == rhs.fileID && lhs.filePath == rhs.filePath
            && lhs.line == rhs.line && lhs.column == rhs.column
    }
}

public struct MockIssue: Sendable {
    public enum Kind: Sendable { case unexpectedCall, verificationFailed }
    public let kind: Kind
    public let endpoint: EndpointID
    public let message: String
    public let source: SourceLocation
    public let watermark: UInt64
}

public struct FailureReporter: Sendable {
    private let body: @Sendable (MockIssue) -> Void
    public init(_ body: @escaping @Sendable (MockIssue) -> Void) { self.body = body }
    public func report(_ issue: MockIssue) { body(issue) }
}

public struct Matcher<Input: Sendable>: Sendable {
    private let body: @Sendable (Input) -> Bool
    public init(_ body: @escaping @Sendable (Input) -> Bool) { self.body = body }
    public func matches(_ input: Input) -> Bool { body(input) }
    public static var any: Self { Self { _ in true } }
}
extension Matcher where Input: Equatable {
    public static func equal(_ expected: Input) -> Self { Self { $0 == expected } }
}

public struct CallCount: Sendable {
    private enum Bound: Sendable { case exact(Int), minimum(Int), maximum(Int) }
    private let bound: Bound
    public static var once: Self { .exactly(1) }
    public static var never: Self { .exactly(0) }
    public static func exactly(_ value: Int) -> Self {
        precondition(value >= 0, "Call counts must be nonnegative")
        return Self(bound: .exact(value))
    }
    public static func atLeast(_ value: Int) -> Self {
        precondition(value >= 0, "Call counts must be nonnegative")
        return Self(bound: .minimum(value))
    }
    public static func atMost(_ value: Int) -> Self {
        precondition(value >= 0, "Call counts must be nonnegative")
        return Self(bound: .maximum(value))
    }
    func accepts(_ actual: Int) -> Bool {
        switch bound {
        case .exact(let n): actual == n
        case .minimum(let n): actual >= n
        case .maximum(let n): actual <= n
        }
    }
    var description: String {
        switch bound {
        case .exact(let n): "exactly \(n)"
        case .minimum(let n): "at least \(n)"
        case .maximum(let n): "at most \(n)"
        }
    }
}

/// Admission queries include unfinished and throwing calls; terminal phases are explicit.
public enum CallPhase: Sendable { case admitted, returned, threw, terminated }
public struct Invocation<Input: Sendable>: Sendable {
    public let id: UInt64
    public let input: Input
    public fileprivate(set) var phase: CallPhase
}
public struct VerificationResult: Sendable {
    public let passed: Bool
    public let observed: Int
    public let watermark: UInt64
    public let invocationIDs: [UInt64]
}

private final class Journal<Input: Sendable>: Sendable {
    private struct State: Sendable {
        var nextID: UInt64 = 0
        var calls: [Invocation<Input>] = []
        var issues: [MockIssue] = []
    }
    private let state = CriticalState(State())
    let endpoint: EndpointID
    private let reporter: FailureReporter
    init(endpoint: EndpointID, reporter: FailureReporter) {
        self.endpoint = endpoint; self.reporter = reporter
    }
    func begin(_ input: Input) -> UInt64 {
        state.withLock {
            $0.nextID += 1
            let id = $0.nextID
            $0.calls.append(Invocation(id: id, input: input, phase: .admitted))
            return id
        }
    }
    func complete(_ id: UInt64, phase: CallPhase) {
        state.withLock {
            // IDs are one-based, append-only, and endpoint-local in this initial slice.
            $0.calls[Int(id - 1)].phase = phase
        }
    }
    func snapshot() -> (calls: [Invocation<Input>], watermark: UInt64) {
        state.withLock { ($0.calls, $0.nextID) }
    }
    func report(_ issue: MockIssue) {
        state.withLock { $0.issues.append(issue) }
        reporter.report(issue) // Consumer code must run after releasing synchronization.
    }
}

public struct Verification<Input: Sendable>: Sendable {
    fileprivate let journal: Journal<Input>
    fileprivate let matcher: Matcher<Input>
    fileprivate let phase: CallPhase
    @discardableResult
    public func wasCalled(_ count: CallCount, fileID: String = #fileID,
                          staticFilePath: StaticString = #filePath, line: Int = #line,
                          column: Int = #column) -> VerificationResult {
        verifyCount(count, source: SourceLocation(fileID: fileID, staticFilePath: staticFilePath,
                                                  line: line, column: column))
    }

    @discardableResult
    public func wasCalled(_ count: CallCount, fileID: String = #fileID,
                          filePath: String, line: Int = #line,
                          column: Int = #column) -> VerificationResult {
        verifyCount(count, source: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    private func verifyCount(_ count: CallCount, source: @autoclosure () -> SourceLocation) -> VerificationResult {
        let prefix = journal.snapshot()
        let matches = prefix.calls.filter {
            (phase == .admitted || $0.phase == phase) && matcher.matches($0.input)
        }
        let passed = count.accepts(matches.count)
        if !passed {
            journal.report(MockIssue(
                kind: .verificationFailed, endpoint: journal.endpoint,
                message: "Expected \(count.description) calls; observed \(matches.count)",
                source: source(),
                watermark: prefix.watermark))
        }
        return VerificationResult(passed: passed, observed: matches.count,
                                  watermark: prefix.watermark, invocationIDs: matches.map(\.id))
    }
}

private struct Rule<Input: Sendable, Answer: Sendable>: Sendable {
    let matcher: Matcher<Input>
    let answer: Answer
}

public struct SyncConfiguration<Input: Sendable, Output: Sendable>: Sendable {
    fileprivate let rules: [Rule<Input, @Sendable (Input) -> Output>]
}
/// Setup is confined to its caller. finish() publishes an immutable plan.
public final class SyncStubbing<Input: Sendable, Output: Sendable> {
    private var rules: [Rule<Input, @Sendable (Input) -> Output>] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> SyncStub<Input, Output> {
        SyncStub(owner: self, matcher: matcher)
    }
    fileprivate func add(_ matcher: Matcher<Input>, _ answer: @escaping @Sendable (Input) -> Output) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: answer))
    }
    public func finish() -> SyncConfiguration<Input, Output> {
        precondition(!finished, "Setup is already published")
        finished = true
        return SyncConfiguration(rules: rules)
    }
}
public struct SyncStub<Input: Sendable, Output: Sendable> {
    fileprivate let owner: SyncStubbing<Input, Output>
    fileprivate let matcher: Matcher<Input>
    public func willReturn(_ output: Output) { owner.add(matcher) { _ in output } }
    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) { owner.add(matcher, answer) }
}

public final class SyncEndpoint<Input: Sendable, Output: Sendable>: Sendable {
    private let configuration: SyncConfiguration<Input, Output>
    private let journal: Journal<Input>
    public init(id: EndpointID, configuration: SyncConfiguration<Input, Output>,
                failureReporter: FailureReporter) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter)
    }
    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) -> Output {
        let id = journal.begin(input)
        // Last registration wins. Matching and answer execution are outside the journal lock.
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            let result = rule.answer(input)
            journal.complete(id, phase: .returned)
            return result
        }
        journal.complete(id, phase: .terminated)
        let issue = MockIssue(kind: .unexpectedCall, endpoint: journal.endpoint,
                              message: "No matching stub for \(journal.endpoint.rawValue)",
                              source: source, watermark: id)
        journal.report(issue)
        fatalError(issue.message)
    }
    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        Verification(journal: journal, matcher: matcher, phase: phase)
    }
    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}

// Storing a typed-throwing function in a generic rule needs a newer OS runtime.
// The stored Result preserves the public typed error on the original deployment floors.
private typealias AsyncAnswer<Input, Output, Failure: Error> =
    @Sendable (Input) async -> Result<Output, Failure>

public struct AsyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let rules: [Rule<Input, AsyncAnswer<Input, Output, Failure>>]
}
public final class AsyncThrowingStubbing<Input: Sendable, Output: Sendable, Failure: Error> {
    private var rules: [Rule<Input, AsyncAnswer<Input, Output, Failure>>] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> AsyncThrowingStub<Input, Output, Failure> {
        AsyncThrowingStub(owner: self, matcher: matcher)
    }
    fileprivate func add(_ matcher: Matcher<Input>,
                         _ answer: @escaping AsyncAnswer<Input, Output, Failure>) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: answer))
    }
    public func finish() -> AsyncThrowingConfiguration<Input, Output, Failure> {
        precondition(!finished, "Setup is already published")
        finished = true
        return AsyncThrowingConfiguration(rules: rules)
    }
}
public struct AsyncThrowingStub<Input: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let owner: AsyncThrowingStubbing<Input, Output, Failure>
    fileprivate let matcher: Matcher<Input>
    public func willReturn(_ output: Output) { owner.add(matcher) { _ in .success(output) } }
    public func willThrow(_ error: Failure) {
        owner.add(matcher) { _ in .failure(error) }
    }
    public func willAnswer(_ answer: @escaping @Sendable (Input) async throws(Failure) -> Output) {
        owner.add(matcher) { input in
            do throws(Failure) { return .success(try await answer(input)) }
            catch { return .failure(error) }
        }
    }
}

public final class AsyncThrowingEndpoint<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let configuration: AsyncThrowingConfiguration<Input, Output, Failure>
    private let journal: Journal<Input>
    private let failureMapping: (@Sendable (MockIssue) -> Failure)?
    public init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                failureMapping: (@Sendable (MockIssue) -> Failure)? = nil) {
        self.configuration = configuration; self.failureMapping = failureMapping
        self.journal = Journal(endpoint: id, reporter: failureReporter)
    }
    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async throws(Failure) -> Output {
        let id = journal.begin(input)
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            switch await rule.answer(input) {
            case .success(let result):
                journal.complete(id, phase: .returned)
                return result
            case .failure(let error):
                journal.complete(id, phase: .threw)
                throw error
            }
        }
        let issue = MockIssue(kind: .unexpectedCall, endpoint: journal.endpoint,
                              message: "No matching stub for \(journal.endpoint.rawValue)",
                              source: source, watermark: id)
        if let failureMapping {
            journal.complete(id, phase: .threw)
            journal.report(issue) // A caught mapped error must still report a test failure.
            throw failureMapping(issue)
        }
        journal.complete(id, phase: .terminated)
        journal.report(issue)
        fatalError(issue.message)
    }
    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        Verification(journal: journal, matcher: matcher, phase: phase)
    }
    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}
