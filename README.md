# Blueprint Mocking

Blueprint Mocking generates typed Swift test doubles. The public prototype implements the first protocol workflow. The [acceptance roadmap](Docs/Acceptance-Status.csv) tracks the 125 contracts from architecture edition 1.0.

The first implemented slice generates a checked Sendable protocol mock, configures typed answers, injects it into a real service, and verifies calls. Configuration and verification use descriptors; neither executes a production requirement. Runtime, generation, and runner reporting have separate source boundaries.

Run from this directory on the tested Xcode toolchain:

```sh
python3 scripts/verify.py
```

That entry point regenerates the consumer mock, runs runtime and consumer tests, executes the example, checks compiler and generator rejections, runs deliberate failures in child processes, and checks runtime-only linkage. It writes local results and the toolchain profile to the ignored `Evidence/` directory.

For the ordinary SwiftPM entry points after generation:

```sh
swift test
swift test --package-path Fixtures/ProtocolConsumer
swift run --package-path Fixtures/ProtocolConsumer consumer-demo
```

The generated source is included so the consumer can build directly. Regenerate it with:

```sh
bash scripts/generate.sh \
  --input Fixtures/ProtocolConsumer/Sources/ConsumerDomain/UserRepository.swift \
  --module ConsumerDomain --protocol UserRepository \
  --output Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/UserRepositoryMock.swift
```

A test uses the production interface without adding mocking imports to its module:

```swift
let mock = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
    stubs.fetchUser(id: .equal("42")).willReturn("Ada")
}
let service = UserService(repository: mock)
#expect(try await service.load(id: "42") == "Ada")
mock.verify.fetchUser(id: .equal("42")).wasCalled(.once)
```

Select the `BluepringMockingFramework` SwiftPM library product in your test target and import its `BlueprintMocking` module. Add the `BlueprintMockingTesting` product and import its module to use the optional `.swiftTesting` reporter. The consumer’s production target depends only on the domain interface.

The implemented generator profile accepts a top-level public protocol inheriting only Sendable, with one String argument and String result per requirement. It supports synchronous nonthrowing methods and async throws(NamedError), including overloads distinguished by argument labels. Other members, effects, actor annotations, and generic signatures receive a location diagnostic before output changes. SwiftParser/SwiftSyntax come from the installed Xcode toolchain through a separate prototype host script. This is a real parser and witness generator, with consumer compilation as its conformance check; semantic module resolution and the distributable tooling package remain unimplemented.

The runtime supports exact/any/custom typed matchers, last-registration-wins rules, immutable setup plans, return/answer stubs, typed async errors, admission/returned/threw count queries, and exact/minimum/maximum counts. Each endpoint has its own typed storage and append-only journal. No Any result casting, process-global registry, detached answer task, or unchecked Sendable conformance is used. User matchers, answers, and reporters execute outside journal synchronization.

Unexpected value calls report before termination. Async typed-throwing endpoints optionally accept an explicit mapping to their declared failure type; catching that error does not suppress reporting. Generated mapping arguments are currently numbered by canonical endpoint order and remain provisional. Verification reports a snapshot watermark and caller source location. Journal IDs are endpoint-local; session-wide identities and lifecycle operations are not implemented.

The tested profile is **Apple Swift 6.4, Swift 6 language mode, arm64 macOS 27 execution, macOS 27 SDK**, compiling with deployment target macOS 15. The prototype uses Synchronization.Mutex and therefore selects macOS 15 in its manifests. The architecture's macOS 13/iOS 16 and other platform floors still require the audited fallback backend and native certification. Swift 6.0/6.2, older OS execution, other default-isolation modes, Linux, Windows, and mobile platforms were not verified.

The MainActor example injects this Sendable mock into a MainActor service. It does not establish actor-specific mock support. Histories retain Sendable inputs directly; the example's String arguments are value snapshots. General projection, redaction, retention budgets, session coordination, reset/reconfiguration, sequences, generic/ownership-sensitive declarations, class/Objective-C adapters, XCTest, plugins, migration and release certification remain roadmap work.

See the [implementation evidence](Docs/Implementation-Evidence.md) for the verified scope and the next slice. The [contribution guide](CONTRIBUTING.md) explains the TDD workflow and how to submit a milestone.

This repository is licensed under the [MIT License](LICENSE).
