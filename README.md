# Blueprint Mocking

Blueprint Mocking generates typed Swift test doubles. The public prototype supports generated Sendable and MainActor protocol mocks. The [acceptance roadmap](Docs/Acceptance-Status.csv) tracks the 125 contracts from architecture edition 1.0.

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

Select the `BluepringMockingFramework` SwiftPM library product in your test target and import its `BlueprintMocking` module. Add the `BlueprintMockingTesting` product and import its module to use the optional `.swiftTesting` reporter. For XCTest, select `BlueprintMockingXCTest`, import its module, and pass `.xctest` as the reporter. Verification failures in XCTest use the assertion’s file and line when supplied as compiler literals. The consumer’s production target depends only on the domain interface.

The generator accepts top-level public protocols in two profiles: a protocol inheriting only Sendable, or an `@MainActor` protocol without inheritance. Both support zero or more parameters and simple named types, including nested optionals, arrays, and dictionaries. A Sendable mock requires Sendable inputs and results. MainActor mocks can retain actor-local, non-Sendable references. Methods support sync, sync throws, async, async throws, Void, Never and named error types. Overloads may differ by argument label or input type. A multi-argument answer receives an ordered tuple, while setup and verification accept one typed matcher per argument. SwiftParser and SwiftSyntax come from the installed Xcode toolchain, and the verification suite compiles each generated conformance.

The runtime supports typed equality, identity, optional, collection, string, numeric, custom and short-circuit logical matchers, last-registration-wins rules, immutable setup plans, return/answer stubs, typed async errors, admission/returned/threw count queries, and exact, minimum, maximum and inclusive-range counts. Use `.and`, `.or` and `.not()` to compose count predicates. An impossible combination produces a contradiction diagnostic. Each endpoint has its own typed storage and append-only journal. No Any result casting, process-global registry, detached answer task, or unchecked Sendable conformance is used. User matchers, answers, and reporters execute outside journal synchronization.

Unstubbed nonthrowing Void calls report and return. An unstubbed value call reports before termination unless the endpoint has an explicit typed fallback. Methods declared `throws(Never)` retain that signature and can be called without `try`. An unstubbed ordinary throwing method reports the issue and throws `UnexpectedInvocationError`. Async typed-throwing endpoints optionally accept an explicit mapping to their declared failure type; catching that error does not suppress reporting. Generated mapping arguments are currently numbered by canonical endpoint order and remain provisional. Verification reports a snapshot watermark and caller source location. Journal IDs are endpoint-local; session-wide identities and lifecycle operations are not implemented.

The runtime manifest declares macOS 13, iOS 16, tvOS 16, watchOS 9 and visionOS 1. The runtime uses Synchronization.Mutex where the OS supports it and NSLock on older Apple targets. The verification suite runs on Apple Swift 6.4 in Swift 6 language mode on arm64 macOS 27. Run `python3 scripts/verify_apple_deployment.py` with all five SDKs installed to link the runtime at the deployment floors, including both macOS architectures. The optional `--pre-mutex-ios-simulator DEVICE` check exercises the fallback lock and typed answers on an existing iOS 16 or 17 simulator. Execution on the exact older Apple releases still requires native testing.

Direct users of the checked Sendable `AsyncThrowingEndpoint` can publish a new configuration with `replaceConfiguration(_:)`. Each call keeps the plan and revision it received at admission through completion. The generated mock API still configures each mock during initialization.

For the Ubuntu 24.04 arm64 runtime profile, run `bash scripts/verify_linux_runtime.sh --help` to prefetch the pinned Swift image, then `bash scripts/verify_linux_runtime.sh` to test a committed revision with networking disabled. The workflow exercises the runtime, archived generated mocks, both reporters, and runtime-only linkage. Linux code generation, Ubuntu 22.04, Linux x86_64 and Windows still require verification.

The MainActor mock keeps setup, matchers, answers, invocation history, and verification on MainActor. A matcher can observe actor-local state, and an answer may return an actor-local reference. History retains those references and evaluates matchers against their state at verification time. The sample includes a consumer workflow and checks that illegal cross-actor access fails compilation. Custom global actors, Actor-constrained protocols, projections, advanced history and sessions, additional declaration families, plugins, migration and release certification remain roadmap work.

See the [implementation evidence](Docs/Implementation-Evidence.md) for the verified scope and the next slice. The [contribution guide](CONTRIBUTING.md) explains the TDD workflow and how to submit a milestone.

This repository is licensed under the [MIT License](LICENSE).
