import ParentDomain

public protocol IntDirectory: ParentDomain.BoundParent<Swift.Int> {
    func save(_ value: Element)
}

public func refreshIntDirectory(_ directory: any IntDirectory, key: String) -> Int {
    let result = directory.load(key: key)
    directory.save(result)
    return result
}
