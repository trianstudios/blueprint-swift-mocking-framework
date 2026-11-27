public protocol ImportedDirectory: Sendable {
    func lookup(id: String) -> String
}

public func importedLookup(_ directory: any ImportedDirectory, id: String) -> String {
    directory.lookup(id: id)
}
