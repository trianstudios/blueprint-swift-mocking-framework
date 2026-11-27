import BlueprintMocking
import Testing

private struct SafeRecipeDomainValue: Hashable, Sendable {
    let id: Int
}

@Test func RUN017_safePrimitivePresetIsOptInAndCanBeOverridden() throws {
    let empty = DefaultValueRegistry()
    let preset = DefaultValueRegistry.safePrimitives()
    let overridden = preset.registering(Int.self) { _ in 17 }

    #expect(throws: DefaultValueResolutionError.unregistered(typeName: String(reflecting: Bool.self))) {
        try empty.require(Bool.self)
    }
    #expect(try preset.require(Bool.self) == false)
    #expect(try preset.require(Int.self) == 0)
    #expect(try preset.require(String.self) == "")
    #expect(try overridden.require(Int.self) == 17)
    #expect(try preset.require(Int.self) == 0)
    #expect(try overridden.require(Bool.self) == false)
}

@Test func RUN017_safeContainerRecipesRegisterOnlyTheirExactTypes() throws {
    let preset = DefaultValueRegistry.safePrimitives()
    let shapes = preset
        .registeringNil(SafeRecipeDomainValue?.self)
        .registeringEmpty([SafeRecipeDomainValue].self)
        .registeringEmpty([SafeRecipeDomainValue: String].self)
        .registeringEmpty(Set<SafeRecipeDomainValue>.self)

    #expect(throws: DefaultValueResolutionError.unregistered(
        typeName: String(reflecting: SafeRecipeDomainValue?.self)
    )) {
        try preset.require(SafeRecipeDomainValue?.self)
    }
    #expect(try shapes.require(SafeRecipeDomainValue?.self) == nil)
    #expect(try shapes.require([SafeRecipeDomainValue].self).isEmpty)
    #expect(try shapes.require([SafeRecipeDomainValue: String].self).isEmpty)
    #expect(try shapes.require(Set<SafeRecipeDomainValue>.self).isEmpty)
    #expect(throws: DefaultValueResolutionError.unregistered(
        typeName: String(reflecting: SafeRecipeDomainValue.self)
    )) {
        try shapes.require(SafeRecipeDomainValue.self)
    }
    #expect(throws: DefaultValueResolutionError.unregistered(typeName: String(reflecting: [Int].self))) {
        try shapes.require([Int].self)
    }

    let value = SafeRecipeDomainValue(id: 23)
    let overridden = shapes
        .registering(SafeRecipeDomainValue?.self) { _ in value }
        .registering([SafeRecipeDomainValue].self) { _ in [value] }
    #expect(try overridden.require(SafeRecipeDomainValue?.self) == value)
    #expect(try overridden.require([SafeRecipeDomainValue].self) == [value])
    #expect(try shapes.require(SafeRecipeDomainValue?.self) == nil)
    #expect(try shapes.require([SafeRecipeDomainValue].self).isEmpty)
}
