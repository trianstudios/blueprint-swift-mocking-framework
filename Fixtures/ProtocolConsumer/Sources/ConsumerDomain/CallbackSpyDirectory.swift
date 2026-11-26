public protocol CallbackSpyDirectory: Sendable {
    func transform(id: String, using callback: (Int) -> String) -> String
    func withoutMetadata(_ callback: (Int) -> String) -> String
    func summarize(_ id: String, offset: Int, using callback: (Int) -> String) -> String
}
