import ParentDomain

public protocol ImportedAssociatedDirectory<Element>: ParentDomain.ForeignAssociatedDirectory {
    func save(_ value: Element)
}
