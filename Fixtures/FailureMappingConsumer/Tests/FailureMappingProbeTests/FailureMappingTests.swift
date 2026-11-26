import Foundation
import Testing
import BlueprintMocking
import ProbeDomain
import ProbeDoubles

private final class ProbeIssueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [MockIssue] = []

    func record(_ issue: MockIssue) {
        lock.lock()
        defer { lock.unlock() }
        issues.append(issue)
    }

    func snapshot() -> [MockIssue] {
        lock.lock()
        defer { lock.unlock() }
        return issues
    }
}

@Test func GEN007_namedFailureMappingKeepsTheOriginalEndpointAcrossRegeneration() {
    let session = MockSession()
    let issues = ProbeIssueLog()
    let zeta = EndpointID("schema1|ProbeDomain.Probe|zeta() throws(ProbeFailure)->String|Sendable")
    let mock = ProbeMock(
        failureReporter: FailureReporter { issues.record($0) },
        session: session,
        failureMappings: .init { mappings in
            mappings.zeta { issue in
                #expect(issue.kind == .unexpectedCall)
                #expect(issue.endpoint == zeta)
                #expect(issues.snapshot().map(\.endpoint) == [zeta])
                return .mapped
            }
        }
    ) { _ in }
    let dependency: any Probe = mock

    do throws(ProbeFailure) {
        _ = try dependency.zeta()
        Issue.record("Expected the original zeta witness to throw ProbeFailure.mapped")
    } catch {
        #expect(error == .mapped)
    }

    #expect(issues.snapshot().map(\.endpoint) == [zeta])
    #expect(mock.verify.zeta(phase: .threw).wasCalled(.once).passed)
    let events = session.snapshot().events
    #expect(events.map(\.endpoint) == [zeta, zeta])
    #expect(events.map(\.phase) == [.admitted, .threw])
}

@Test func GEN007_failureMappingsSelectOverloadsByArgumentType() {
    let issues = ProbeIssueLog()
    let mock = ProbeMock(
        failureReporter: FailureReporter { issues.record($0) },
        failureMappings: .init { mappings in
            mappings.lookup(id: Int.self) { _ in .integer }
            mappings.lookup(id: String.self) { _ in .string }
        }
    ) { _ in }
    let dependency: any Probe = mock

    #expect(throws: ProbeFailure.integer) { try dependency.lookup(id: 7) }
    #expect(throws: ProbeFailure.string) { try dependency.lookup(id: "7") }
    #expect(mock.verify.lookup(id: .equal(7), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.lookup(id: .equal("7"), phase: .threw).wasCalled(.once).passed)
    let signatures = issues.snapshot().map { $0.endpoint.rawValue }
    #expect(signatures.count == 2)
    #expect(signatures.first?.contains("|lookup(id:Int)") == true)
    #expect(signatures.last?.contains("|lookup(id:String)") == true)
}
