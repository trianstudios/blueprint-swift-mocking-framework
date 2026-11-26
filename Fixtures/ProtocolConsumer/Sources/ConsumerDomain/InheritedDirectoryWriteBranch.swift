public protocol InheritedDirectoryWriteBranch: InheritedDirectoryRoot {
    func rename(to label: String) -> String
}
