public protocol WritableSpyDirectory: Sendable {
    var title: String { get nonmutating set }
    subscript(slot slot: Int) -> Int { get nonmutating set }
}

public struct WritableSpyClient: Sendable {
    private let directory: any WritableSpyDirectory

    public init(directory: any WritableSpyDirectory) {
        self.directory = directory
    }

    public func appendToTitle(_ suffix: String) {
        directory.title += suffix
    }

    public func rename(to title: String) {
        directory.title = title
    }

    public func increaseScore(in slot: Int, by increment: Int) {
        directory[slot: slot] += increment
    }

    public func setScore(_ score: Int, in slot: Int) {
        directory[slot: slot] = score
    }
}
