#if canImport(ParentDomain)
import ParentDomain
#endif

public protocol QualifiedConditionalImport: ParentDomain.SharedDirectory, Sendable {}
