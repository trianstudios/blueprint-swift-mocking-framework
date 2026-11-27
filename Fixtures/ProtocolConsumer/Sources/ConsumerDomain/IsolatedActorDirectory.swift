public actor IsolatedDirectoryWorker {
    public private(set) var count = 0

    public init() {}

    public func increment() {
        count += 1
    }

    public func sampleOnOwner(using directory: any IsolatedActorDirectory) -> Int {
        directory.sample(self)
    }
}

public protocol IsolatedActorDirectory: Sendable {
    func sample(_ worker: isolated IsolatedDirectoryWorker) -> Int
    func label(for name: String) -> String
}
