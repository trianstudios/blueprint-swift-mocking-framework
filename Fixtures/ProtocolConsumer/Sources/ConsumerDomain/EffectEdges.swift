/// Requirements that exercise void, uninhabited results, and uninhabited errors.
public protocol EffectEdges: Sendable {
    func record(id: String)
    func flush(id: String) async -> ()
    func read(id: String) throws(Never) -> String
    func readAsync(id: String) async throws(Never) -> String
    func stop(id: String) -> Never
}
