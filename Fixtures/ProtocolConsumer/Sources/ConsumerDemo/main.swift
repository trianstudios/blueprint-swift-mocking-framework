import Foundation
import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

@main struct Demo {
    static func main() async throws {
        let reporter = FailureReporter { issue in
            FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
        }
        if CommandLine.arguments.contains("--typed-throwing-callback") {
            try verifyThrowingCallback(reporter: reporter)
            try await verifyAsyncThrowingCallback(reporter: reporter)
            try await MainActor.run { try verifyMainActorThrowingCallback(reporter: reporter) }
            try await verifyMainActorAsyncThrowingCallback(reporter: reporter)
            return
        }
        if CommandLine.arguments.contains("--quiescent-configuration") {
            try await verifyQuiescentConfiguration(reporter: reporter)
            return
        }
        if CommandLine.arguments.contains("--missing-generic-specialization") {
            let session = MockSession()
            let reporter = FailureReporter { issue in
                let events = session.snapshot().events
                precondition(events.count == 2 && events[0].phase == .admitted && events[1].phase == .terminated)
                precondition(events[0].invocationID == events[1].invocationID)
                precondition(events.allSatisfy { $0.endpoint == issue.endpoint })
                precondition(issue.endpoint.specialization?.typeName == String(reflecting: Bool.self))
                FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
            }
            let mock = GenericSubscriptDirectoryMock(failureReporter: reporter, session: session) { _ in }
            let service = GenericSubscriptClient(directory: mock)
            _ = service.read(true)
        }
        if CommandLine.arguments.contains("--closed-generic-provider") {
            try verifyClosedGenericProvider()
            return
        }
        if CommandLine.arguments.contains("--missing-generic-method-specialization") {
            let session = MockSession()
            let reporter = FailureReporter { issue in
                let events = session.snapshot().events
                precondition(events.map(\.phase) == [.admitted, .terminated])
                precondition(events[0].invocationID == events[1].invocationID)
                precondition(events.allSatisfy { $0.endpoint == issue.endpoint })
                precondition(issue.endpoint.specialization?.typeName == String(reflecting: Bool.self))
                FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
            }
            let mock = GenericMethodDirectoryMock(failureReporter: reporter, session: session) { _ in }
            let service = GenericMethodClient(directory: mock)
            _ = service.transform(true)
        }
        if CommandLine.arguments.contains("--type-subscript-closed-orphan") {
            let session = MockSession(orphanFailures: OrphanFailureBuffer())
            let ownerReporter = FailureReporter { _ in fatalError("Closed orphan reached the owning reporter") }
            let scope = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: ownerReporter, session: session) { _ in }
            try session.finishIfQuiescent()
            _ = scope.withValue { TypeSubscriptClient.read(7, using: TypeSubscriptDirectoryMock.self) }
            return
        }
        if CommandLine.arguments.contains("--type-subscript-unbound-setter") {
            TypeSubscriptDirectoryMock[7] = 20
            print("PASS: unbound type setter returned after diagnosis")
            return
        }
        if CommandLine.arguments.contains("--type-subscript-detached") {
            let scope = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: reporter) { stubs in
                stubs.get_subscript(.any).willReturn(12)
            }
            await scope.withValue {
                let detached = Task.detached {
                    TypeSubscriptClient.read(7, using: TypeSubscriptDirectoryMock.self)
                }
                _ = await detached.value
            }
        }
        if CommandLine.arguments.contains("--type-subscript-stale") {
            let session = MockSession()
            let reporter = FailureReporter { issue in
                precondition(session.snapshot().events.isEmpty)
                FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
            }
            let scope = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: reporter, session: session) { stubs in
                stubs.get_subscript(.any).willReturn(12)
            }
            try session.resetHistory()
            _ = scope.withValue { TypeSubscriptClient.read(7, using: TypeSubscriptDirectoryMock.self) }
        }
        if CommandLine.arguments.contains("--missing-never") {
            let mock = EffectEdgesMock(failureReporter: reporter) { _ in }
            mock.stop(id: "unstubbed")
        }
        let mock = UserRepositoryMock(failureReporter: reporter) { stubs in
            stubs.fetchUser(id: .equal("42")).willReturn("Ada")
            stubs.greeting(for: .any).willAnswer { "Hello, " + $0 }
        }
        if CommandLine.arguments.contains("--missing-sync") {
            _ = mock.greeting("unstubbed")
            return
        }
        if CommandLine.arguments.contains("--missing") {
            _ = try await mock.fetchUser(id: "unstubbed")
            return
        }
        let service = UserService(repository: mock)
        let value = try await service.load(id: "42")
        precondition(value == "Ada")
        precondition(mock.greeting(for: value) == "Hello, Ada")
        precondition(mock.verify.fetchUser(id: .equal("42")).wasCalled(.once).passed)
        precondition(mock.verify.greeting(for: .equal("Ada")).wasCalled(.once).passed)
        print("PASS: generated protocol → typed stubs → service → exact verification")
    }

    private static func verifyThrowingCallback(reporter: FailureReporter) throws {
        let session = MockSession()
        let captor = ThrowingEscapingCallbackCaptor<Int, String, CallbackFixtureError>(session: session)
        let mock = ThrowingEscapingCallbackDirectoryMock(failureReporter: reporter, session: session) { stubs in
            stubs.register(id: .equal("row")).capturingCallback(into: captor).willReturn("registered")
        }
        let registration = registerThrowingEscapingCallback(mock, id: "row") { input throws(CallbackFixtureError) in
            guard input >= 0 else { throw .rejected(input) }
            return "replayed-\(input)"
        }
        precondition(registration == "registered")
        guard let capture = captor.captures.first else { preconditionFailure("No callback captured") }

        let success = try capture.invoke(7, onUnavailable: { .unavailable })
        precondition(success == "replayed-7")
        do throws(CallbackFixtureError) {
            _ = try capture.invoke(-7, onUnavailable: { .unavailable })
            preconditionFailure("Expected the callback's typed failure")
        } catch {
            precondition(error == .rejected(-7))
        }
        precondition(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
        print("PASS: GEN016 executable replayed a typed callback success and failure")
    }

    private static func verifyAsyncThrowingCallback(reporter: FailureReporter) async throws {
        let session = MockSession()
        let captor = AsyncThrowingEscapingCallbackCaptor<Int, String, AsyncCallbackFixtureError>(session: session)
        let mock = AsyncThrowingEscapingCallbackDirectoryMock(failureReporter: reporter, session: session) { stubs in
            stubs.register(id: .equal("row")).capturingCallback(into: captor).willReturn("registered")
        }
        let registration = registerAsyncThrowingEscapingCallback(mock, id: "row") {
            input async throws(AsyncCallbackFixtureError) in
            await Task.yield()
            guard input >= 0 else { throw .rejected(input) }
            return "replayed-\(input)"
        }
        precondition(registration == "registered")
        guard let capture = captor.captures.first else { preconditionFailure("No async callback captured") }

        let success = try await capture.invoke(7, onUnavailable: { .unavailable(7) })
        precondition(success == "replayed-7")
        do throws(AsyncCallbackFixtureError) {
            _ = try await capture.invoke(-7, onUnavailable: { .unavailable(-7) })
            preconditionFailure("Expected the async callback's typed failure")
        } catch {
            precondition(error == .rejected(-7))
        }
        precondition(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
        print("PASS: GEN016 executable replayed an async typed callback success and failure")
    }

    @MainActor
    private static func verifyMainActorThrowingCallback(reporter: FailureReporter) throws {
        let session = MockSession()
        let captor = MainActorThrowingEscapingCallbackCaptor<Int, String, MainActorCallbackFixtureError>(session: session)
        let mock = MainActorThrowingEscapingCallbackDirectoryMock(failureReporter: reporter, session: session) { stubs in
            stubs.register(id: .equal("row")).capturingCallback(into: captor).willReturn("registered")
        }
        let registration = registerMainActorThrowingEscapingCallback(mock, id: "row") {
            input throws(MainActorCallbackFixtureError) in
            MainActor.preconditionIsolated()
            guard input >= 0 else { throw .rejected(input) }
            return "replayed-\(input)"
        }
        precondition(registration == "registered")
        guard let capture = captor.captures.first else { preconditionFailure("No MainActor callback captured") }

        let success = try capture.invoke(7, onUnavailable: { .unavailable })
        precondition(success == "replayed-7")
        do throws(MainActorCallbackFixtureError) {
            _ = try capture.invoke(-7, onUnavailable: { .unavailable })
            preconditionFailure("Expected the MainActor callback's typed failure")
        } catch {
            precondition(error == .rejected(-7))
        }
        precondition(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
        print("PASS: GEN016 executable replayed a MainActor typed callback success and failure")
    }

    @MainActor
    private static func verifyMainActorAsyncThrowingCallback(reporter: FailureReporter) async throws {
        let session = MockSession()
        let captor = MainActorAsyncThrowingEscapingCallbackCaptor<Int, String, MainActorAsyncCallbackFixtureError>(
            session: session
        )
        let mock = MainActorAsyncThrowingEscapingCallbackDirectoryMock(failureReporter: reporter, session: session) { stubs in
            stubs.register(id: .equal("row")).capturingCallback(into: captor).willReturn("registered")
        }
        let registration = registerMainActorAsyncThrowingEscapingCallback(mock, id: "row") {
            input async throws(MainActorAsyncCallbackFixtureError) in
            await Task.yield()
            MainActor.preconditionIsolated()
            guard input >= 0 else { throw .rejected(input) }
            return "replayed-\(input)"
        }
        precondition(registration == "registered")
        guard let capture = captor.captures.first else { preconditionFailure("No MainActor async callback captured") }

        let success = try await capture.invoke(7, onUnavailable: { .unavailable(7) })
        precondition(success == "replayed-7")
        do throws(MainActorAsyncCallbackFixtureError) {
            _ = try await capture.invoke(-7, onUnavailable: { .unavailable(-7) })
            preconditionFailure("Expected the MainActor async callback's typed failure")
        } catch {
            precondition(error == .rejected(-7))
        }
        precondition(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
        print("PASS: GEN016 executable replayed a MainActor async typed callback success and failure")
    }
}
