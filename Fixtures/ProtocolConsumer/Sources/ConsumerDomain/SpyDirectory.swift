public enum SpyDirectoryFailure: Error {
    case offline
    case exhausted
}

public protocol SpyDirectory: Sendable {
    var displayPrefix: String { get }
    subscript(_ key: Int, region region: String) -> String { get }
    func refresh(_ id: String) async -> String
    func display(for id: String) -> String
    func cached(id: String) throws(SpyDirectoryFailure) -> String
    func fetch(id: String) async throws(SpyDirectoryFailure) -> String
}

public struct SpyDirectoryClient: Sendable {
    private let directory: any SpyDirectory

    public init(directory: any SpyDirectory) {
        self.directory = directory
    }

    public func refresh(_ id: String) async -> String {
        await directory.refresh(id)
    }

    public func inspect(_ key: Int, region: String) -> String {
        directory.displayPrefix + directory[key, region: region]
    }

    public func display(for id: String) -> String {
        directory.display(for: id)
    }

    public func cached(id: String) throws(SpyDirectoryFailure) -> String {
        try directory.cached(id: id)
    }

    public func fetch(id: String) async throws(SpyDirectoryFailure) -> String {
        try await directory.fetch(id: id)
    }
}

private actor RemoteRequestLog {
    var ids: [String] = []

    func record(_ id: String) { ids.append(id) }
}

public struct RealSpyDirectory: SpyDirectory {
    private let requests = RemoteRequestLog()

    public init() {}

    public var displayPrefix: String { "real:" }

    public subscript(_ key: Int, region region: String) -> String {
        region + ":" + String(key)
    }

    public func refresh(_ id: String) async -> String {
        await requests.record(id)
        return "refresh:" + id
    }

    public func display(for id: String) -> String {
        "real:" + id
    }

    public func cached(id: String) throws(SpyDirectoryFailure) -> String {
        if id == "cached-offline" { throw .offline }
        return "cache:" + display(for: id)
    }

    public func fetch(id: String) async throws(SpyDirectoryFailure) -> String {
        await requests.record(id)
        if id == "remote-offline" { throw .offline }
        return "fetch:" + display(for: id)
    }

    public func observedRemoteIDs() async -> [String] {
        await requests.ids
    }
}
