import ParentDomain

public protocol ImportedAssociatedDirectory<Element>: ParentDomain.ForeignAssociatedDirectory, ParentDomain.NominalElementBranch {
    func save(_ value: Element)
}
