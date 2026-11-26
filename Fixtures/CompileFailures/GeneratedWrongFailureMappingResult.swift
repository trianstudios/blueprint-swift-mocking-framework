import BlueprintMocking
import ConsumerDoubles

enum WrongFailureMappingError: Error { case unrelated }

func invalid(_ mappings: inout UserRepositoryMock.FailureMappings) {
    mappings.fetchUser(id: String.self) { _ in WrongFailureMappingError.unrelated }
}
