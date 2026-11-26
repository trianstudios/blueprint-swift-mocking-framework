public enum ProbeFailure: Error, Equatable {
    case mapped
    case integer
    case string
}

public protocol Probe: Sendable {
    func lookup(id: Int) throws(ProbeFailure) -> String
    func lookup(id: String) throws(ProbeFailure) -> String
    func zeta() throws(ProbeFailure) -> String
}
