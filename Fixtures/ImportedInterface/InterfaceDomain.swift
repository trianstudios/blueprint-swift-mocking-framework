public protocol ImportedDirectory: Sendable {
    func lookup(id: String) -> String
}

public func importedLookup(_ directory: any ImportedDirectory, id: String) -> String {
    directory.lookup(id: id)
}

public protocol ImportedDirectoryBase: Sendable {
    func enabled(_ id: String) -> Bool
    func mark(_ id: String)
}

public protocol InheritedImportedDirectory: ImportedDirectoryBase {
    func lookup(_ id: String) -> Int
}

public func importedInheritedLookup(_ directory: any InheritedImportedDirectory, id: String) -> Int {
    directory.mark(id)
    return directory.enabled(id) ? directory.lookup(id) : 0
}
