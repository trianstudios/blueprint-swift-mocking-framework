import BlueprintMocking
import ConstructorDomain
import Foundation

private let reporter = FailureReporter { issue in
    let line = "Construction fixture issue: \(issue.message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

private func makeScope(_ session: MockSession, label: String) -> ConstructionDirectoryMock.ConstructionScope {
    ConstructionDirectoryMock.makeConstructionScope(failureReporter: reporter, session: session) { seed, stubs in
        let during = session.snapshot()
        precondition(during.activeInvocationCount == 1 && during.events.last?.phase == .admitted)
        do throws(SessionFinishError) {
            _ = try session.finishIfQuiescent()
            preconditionFailure("Expected an active constructor to prevent finish")
        } catch {
            precondition(error == .activeInvocations(count: 1))
        }
        do throws(SessionResetError) {
            _ = try session.resetHistory()
            preconditionFailure("Expected an active constructor to prevent quiescent reset")
        } catch {
            precondition(error == .activeInvocations(count: 1))
        }
        stubs.label(.any).willAnswer { "\(label)/\(seed)/\($0)" }
    }
}

@main struct IndependentConsumer {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first {
        case "unscoped":
            _ = createDirectory(ConstructionDirectoryMock.self, seed: 11)
        case "unbound-detached":
            let scope = makeScope(MockSession(), label: "unbound")
            _ = await scope.withValue {
                await Task.detached { createDirectory(ConstructionDirectoryMock.self, seed: 11) }.value
            }
        case "stale":
            let session = MockSession()
            let scope = makeScope(session, label: "stale")
            _ = try session.resetHistory()
            _ = scope.withValue { createDirectory(ConstructionDirectoryMock.self, seed: 11) }
        case "finished":
            let session = MockSession()
            let scope = makeScope(session, label: "finished")
            _ = try session.finishIfQuiescent()
            _ = scope.withValue { createDirectory(ConstructionDirectoryMock.self, seed: 11) }
        default:
            try await exercise()
        }
    }

    private static func exercise() async throws {
        let session = MockSession()
        let scope = makeScope(session, label: "main")
        precondition(session.snapshot().events.isEmpty)
        let first = scope.withValue { createDirectory(ConstructionDirectoryMock.self, seed: 11) }
        let second = await Task.detached {
            await scope.withValue {
                await Task.yield()
                return createDirectory(ConstructionDirectoryMock.self, seed: 22)
            }
        }.value
        precondition(first !== second)
        let constructed = session.snapshot().events
        precondition(constructed.map(\.phase) == [.admitted, .returned, .admitted, .returned])
        precondition(constructed[0].invocationID == constructed[1].invocationID)
        precondition(constructed[2].invocationID == constructed[3].invocationID)
        precondition(constructed[0].invocationID != constructed[2].invocationID)
        precondition(constructed[0].mockID != constructed[2].mockID)
        precondition(constructed[0].endpoint.rawValue.contains("init(seed:Swift.Int)"))
        precondition(first.label(1) == "main/11/1")
        precondition(second.label(2) == "main/22/2")
        precondition(first.verify.label(.equal(1), phase: .returned).wasCalled(.once).passed)
        precondition(second.verify.label(.equal(2), phase: .returned).wasCalled(.once).passed)
        let all = session.snapshot().events
        precondition(all.count == 8)
        precondition(constructed[0].mockID == all[4].mockID)
        precondition(constructed[2].mockID == all[6].mockID)
        precondition(constructed[3].ordinal < all[4].ordinal)

        let otherSession = MockSession()
        let otherScope = makeScope(otherSession, label: "other")
        let isolated = scope.withValue {
            otherScope.withValue { createDirectory(ConstructionDirectoryMock.self, seed: 11) }
        }
        precondition(isolated.label(1) == "other/11/1")
        precondition(otherSession.snapshot().events.count == 4)
        precondition(session.snapshot().events == all)

        let resetting = MockSession()
        let originalEpoch = resetting.snapshot().epoch
        let resetScope = ConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: resetting
        ) { _, stubs in
            let during = resetting.snapshot()
            precondition(during.epoch == originalEpoch && during.activeInvocationCount == 1)
            _ = try! resetting.resetHistory(.detachActive)
            precondition(resetting.snapshot().events.isEmpty)
            stubs.label(.any).willReturn("after reset")
        }
        let detached = resetScope.withValue { createDirectory(ConstructionDirectoryMock.self, seed: 3) }
        let archived = resetting.snapshot(epoch: originalEpoch)!
        precondition(archived.activeInvocationCount == 0 && archived.events.map(\.phase) == [.admitted, .returned])
        precondition(archived.events[0].invocationID == archived.events[1].invocationID)
        precondition(detached.label(7) == "after reset")
        let current = resetting.snapshot()
        precondition(current.epoch != originalEpoch && current.events.map(\.phase) == [.admitted, .returned])
        precondition(current.events[0].mockID == archived.events[0].mockID)
        try verifyAbandonedConstruction()
        print("PASS: GEN026 ordinary initializer attempts attach to the exact constructed instances")
    }

    private static func reserveAndDrop(in session: MockSession) -> MockID {
        let attempt = session.makeMock().beginInfallibleConstruction(
            of: EndpointID("construction.drop"), reporter: reporter, source: SourceLocation()
        )
        precondition(session.snapshot().activeInvocationCount == 1)
        return attempt.instanceScope.id
    }

    private static func verifyAbandonedConstruction() throws {
        let session = MockSession()
        let id = reserveAndDrop(in: session)
        let archived = try session.finishIfQuiescent()
        precondition(archived.events.map(\.phase) == [.admitted, .terminated])
        precondition(archived.events.allSatisfy { $0.mockID == id })
        precondition(archived.activeInvocationCount == 0)
    }
}
