public protocol IsolatedAnyCallbackDirectory: Sendable {
    func register(id: String, using callback: @escaping @isolated(any) @Sendable (Int) -> String) -> Bool
}

@globalActor
public actor IsolatedAnyCallbackWorker {
    public static let shared = IsolatedAnyCallbackWorker()
    public private(set) var instanceValue = 0
}

@IsolatedAnyCallbackWorker private var workerTotal = 0
@MainActor private var mainTotal = 0

@IsolatedAnyCallbackWorker
public func isolatedAnyWorkerCallback(_ amount: Int) -> String {
    IsolatedAnyCallbackWorker.shared.preconditionIsolated()
    workerTotal += amount
    return "worker:\(workerTotal)"
}

@MainActor
public func isolatedAnyMainCallback(_ amount: Int) -> String {
    MainActor.preconditionIsolated()
    mainTotal += amount
    return "main:\(mainTotal)"
}
