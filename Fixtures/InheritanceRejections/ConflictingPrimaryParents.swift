import ParentDomain

public protocol IntBranch: ParentDomain.BoundParent<Swift.Int> {}
public protocol StringBranch: ParentDomain.BoundParent<Swift.String> {}
public protocol ConflictingPrimaryParents: IntBranch, StringBranch {}
