import BlueprintMocking
import TypedConstructorDomain

enum ForeignConstructionError: Error { case unavailable }

func configureWrongError() {
    _ = TypedConstructionDirectoryMock.makeConstructionScope(failureReporter: FailureReporter { _ in }) {
        _, _ throws(ForeignConstructionError) in throw .unavailable
    }
}
