import BlueprintMocking
import Dispatch
import Testing

private enum ContextBodyFailure: Error { case deliberate }

@Test func RUN037_syncScopesRestoreTypedFailuresAndNestedBindings() {
    let outer = MockSession()
    let inner = MockSession()
    let outerToken = outer.contextHandle
    let innerToken = inner.contextHandle
    #expect(MockSession.currentContext == nil)

    func typedBody() throws(ContextBodyFailure) {
        try inner.withContext { () throws(ContextBodyFailure) in
            #expect(MockSession.currentContext == innerToken)
            throw .deliberate
        }
    }

    outer.withContext {
        #expect(MockSession.currentContext == outerToken)
        do throws(ContextBodyFailure) { try typedBody() }
        catch { #expect(error == .deliberate) }
        #expect(MockSession.currentContext == outerToken)
    }
    #expect(MockSession.currentContext == nil)
}

@Test func DX024_detachedTasksAndCallbacksRequireExplicitRebinding() async throws {
    let session = MockSession()
    let handle = session.contextHandle

    try await session.withContext {
        let inherited = Task { try session.requireCurrentContext() }
        let inheritedHandle = try await inherited.value
        #expect(inheritedHandle == handle)

        let detached = Task<Result<MockSessionContext, MockSessionContextError>, Never>.detached {
            do throws(MockSessionContextError) { return .success(try session.requireCurrentContext()) }
            catch { return .failure(error) }
        }
        #expect(await detached.value == .failure(.missingContext))

        let rebound = Task.detached {
            let body = try await session.withContext(handle) {
                await Task.yield()
                return try session.requireCurrentContext()
            }
            return [body, MockSession.currentContext]
        }
        let reboundHandles = try await rebound.value
        #expect(reboundHandles == [handle, nil])

        let callback: [MockSessionContext?] = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let before = MockSession.currentContext
                let bound = try? session.withContext(handle) { try session.requireCurrentContext() }
                continuation.resume(returning: [before, bound, MockSession.currentContext])
            }
        }
        #expect(callback == [nil, handle, nil])
        #expect(MockSession.currentContext == handle)
    }
    #expect(MockSession.currentContext == nil)
}

@Test func DX024_foreignAndStaleHandlesCannotRetargetABinding() throws {
    let session = MockSession()
    let foreign = MockSession()
    let captured = session.contextHandle

    try foreign.withContext {
        do throws(MockSessionContextError) {
            _ = try session.requireCurrentContext()
            Issue.record("Expected a foreign-session error")
        } catch {
            #expect(error == .foreignSession(expected: session.id, actual: foreign.id))
        }

        do {
            _ = try foreign.withContext(captured) { Issue.record("Foreign body ran") }
        } catch {
            #expect(error as? MockSessionContextError == .foreignSession(expected: foreign.id, actual: session.id))
        }
        let verified = try foreign.requireCurrentContext()
        #expect(verified == foreign.contextHandle)
    }

    try session.withContext {
        let newEpoch = try session.resetHistory()
        #expect(MockSession.currentContext == captured)
        let stale = MockSessionContextError.staleEpoch(expected: newEpoch, actual: captured.epoch)
        do throws(MockSessionContextError) {
            _ = try session.requireCurrentContext()
            Issue.record("An old lexical token retargeted to the new epoch")
        } catch {
            #expect(error == stale)
        }
        do {
            _ = try session.withContext(captured) { Issue.record("Stale body ran") }
        } catch {
            #expect(error as? MockSessionContextError == stale)
        }
        let renewed = try session.withContext { try session.requireCurrentContext() }
        #expect(renewed.epoch == newEpoch)
        #expect(MockSession.currentContext == captured)
    }
    #expect(MockSession.currentContext == nil)
}

@Test func RUN037_cancelledAsyncBodyRestoresTheParentBinding() async {
    let outer = MockSession()
    let inner = MockSession()
    let (entries, entered) = AsyncStream<Void>.makeStream()
    let task = Task {
        await outer.withContext {
            do {
                try await inner.withContext {
                    #expect(MockSession.currentContext == inner.contextHandle)
                    entered.yield(())
                    entered.finish()
                    try await Task.sleep(for: .seconds(120))
                }
                Issue.record("Expected the inner body to be cancelled")
            } catch {
                #expect(error is CancellationError)
            }
            return MockSession.currentContext
        }
    }
    var gate = entries.makeAsyncIterator()
    _ = await gate.next()
    task.cancel()
    #expect(await task.value == outer.contextHandle)
    #expect(MockSession.currentContext == nil)
}


private final class LocalContextValue {
    var observations = 0
}

@Test @MainActor func RUN037_asyncScopePreservesActorLocalValuesAndTypedBodyErrors() async {
    let session = MockSession()
    let local = LocalContextValue()
    let actual = await session.withContext {
        await Task.yield()
        local.observations += 1
        return local
    }
    #expect(actual === local)

    func fail() async throws(ContextBodyFailure) {
        try await session.withContext { () async throws(ContextBodyFailure) in
            #expect(MockSession.currentContext == session.contextHandle)
            await Task.yield()
            local.observations += 1
            throw .deliberate
        }
    }

    do throws(ContextBodyFailure) {
        try await fail()
        Issue.record("Expected the typed body error")
    } catch {
        #expect(error == .deliberate)
    }
    #expect(local.observations == 2)
    #expect(MockSession.currentContext == nil)
}
