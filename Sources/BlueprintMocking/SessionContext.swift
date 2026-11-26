/// A captured session epoch. Passing a handle never transports a mock or its payloads.
public struct MockSessionContext: Hashable, Sendable {
    public let epoch: SessionEpoch

    public var sessionID: SessionID { epoch.sessionID }

    fileprivate init(epoch: SessionEpoch) {
        self.epoch = epoch
    }
}

public enum MockSessionContextError: Error, Equatable {
    case missingContext
    case finishedSession
    case foreignSession(expected: SessionID, actual: SessionID)
    case staleEpoch(expected: SessionEpoch, actual: SessionEpoch)
}

private enum SessionContextBinding {
    @TaskLocal static var current: MockSessionContext?
}

extension MockSession {
    /// The active lexical binding, if any. Resolve it against a session before using it.
    public static var currentContext: MockSessionContext? { SessionContextBinding.current }

    /// Captures the current epoch for explicit transport to detached work or callbacks.
    public var contextHandle: MockSessionContext { MockSessionContext(epoch: contextEpoch) }

    /// Reads the lexical binding and validates its session and epoch at the time of this check.
    public func requireCurrentContext() throws(MockSessionContextError) -> MockSessionContext {
        guard let handle = Self.currentContext else { throw .missingContext }
        try validateContext(handle)
        return handle
    }

    /// Binds a fresh handle for a synchronous lexical scope.
    public func withContext<Value, Failure: Error>(
        _ body: () throws(Failure) -> Value
    ) throws(Failure) -> Value {
        let result: Result<Value, Failure> = SessionContextBinding.$current.withValue(contextHandle) {
            do throws(Failure) { return .success(try body()) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    /// Binds a fresh handle for an asynchronous lexical scope.
    public func withContext<Value, Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        return try await bind(contextHandle, isolation: isolation, body)
    }

    /// Rebinds a previously captured handle for one synchronous operation.
    public func withContext<Value>(
        _ handle: MockSessionContext,
        _ body: () throws -> Value
    ) throws -> Value {
        try validateContext(handle)
        return try SessionContextBinding.$current.withValue(handle, operation: body)
    }

    /// Rebinds a previously captured handle for one asynchronous operation.
    public func withContext<Value>(
        _ handle: MockSessionContext,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async throws -> Value {
        try validateContext(handle)
        return try await bind(handle, isolation: isolation, body)
    }

    private func bind<Value, Failure: Error>(
        _ handle: MockSessionContext, isolation: isolated (any Actor)?,
        _ body: () async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        #if compiler(>=6.2)
        let operation: nonisolated(nonsending) () async -> Result<Value, Failure> = {
            do throws(Failure) { return .success(try await body()) }
            catch { return .failure(error) }
        }
        let result = await SessionContextBinding.$current.withValue(handle, operation: operation)
        #else
        let result: Result<Value, Failure> = await SessionContextBinding.$current.withValue(
            handle, operation: {
                do throws(Failure) { return .success(try await body()) }
                catch { return .failure(error) }
            }, isolation: isolation
        )
        #endif
        return try result.get()
    }

    private var contextEpoch: SessionEpoch { withLock { $0.epoch } }

    private func validateContext(_ handle: MockSessionContext) throws(MockSessionContextError) {
        guard handle.sessionID == id else {
            throw .foreignSession(expected: id, actual: handle.sessionID)
        }
        let current = withLock { (epoch: $0.epoch, finished: $0.isFinished) }
        guard !current.finished else { throw .finishedSession }
        guard handle.epoch == current.epoch else {
            throw .staleEpoch(expected: current.epoch, actual: handle.epoch)
        }
    }
}
