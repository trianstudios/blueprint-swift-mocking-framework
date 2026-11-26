# Blueprint Mocking

Blueprint Mocking generates typed Swift test doubles. The public prototype supports generated Sendable and MainActor protocol mocks. The [acceptance roadmap](Docs/Acceptance-Status.csv) tracks the 125 contracts from architecture edition 1.0.

The first implemented slice generates a checked Sendable protocol mock, configures typed answers, injects it into a real service, and verifies calls. Configuration and verification use descriptors; neither executes a production requirement. Runtime, generation, and runner reporting have separate source boundaries.

Run from this directory on the tested Xcode toolchain:

```sh
python3 scripts/verify.py
```

That entry point regenerates the consumer mock, runs runtime and consumer tests, executes the example, checks compiler and generator rejections, runs deliberate failures in child processes, and checks runtime-only linkage. It writes local results and the toolchain profile to the ignored `Evidence/` directory. The profile records the source revision when the checkout is clean and unchanged across the run. Hashes bind the profile to the results and each result to its log.

For the ordinary SwiftPM entry points after generation:

```sh
swift test
swift test --package-path Fixtures/ProtocolConsumer
swift run --package-path Fixtures/ProtocolConsumer consumer-demo
```

### SwiftPM build-tool generation

To build mocks from source in a SwiftPM test or test-support target, add the runtime and tooling packages from a local checkout of this repository. Set the target’s dependencies to include the protocol’s Swift source target and the runtime product. Attach `BlueprintMockingBuildPlugin` from the tooling package.

```swift
.package(name: "BluepringMockingFramework", path: "../blueprint-swift-mocking"),
.package(name: "BlueprintMockingTools", path: "../blueprint-swift-mocking/Packages/Tooling"),
```

```swift
.testTarget(
    name: "AppTests",
    dependencies: [
        "AppDomain",
        .product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
    ],
    plugins: [.plugin(name: "BlueprintMockingBuildPlugin", package: "BlueprintMockingTools")]
)
```

Create `blueprint-mocking.json` at the consumer package root. Use the Swift module name and select top-level public protocols that the generator supports.

```json
{
  "schemaVersion": 1,
  "selections": [{"module": "AppDomain", "type": "UserRepository", "kind": "protocol"}]
}
```

A schema 1 selection can supply explicit associated-type bindings. Use one entry per associated type.

```json
{
  "schemaVersion": 1,
  "selections": [
    {
      "module": "AppDomain",
      "type": "Repository",
      "kind": "protocol",
      "associatedTypeBindings": [{"name": "Element", "type": "String"}]
    }
  ]
}
```

The plugin uses the same binding validation as standalone generation. Changing the configured type regenerates the mock and its index. A conflicting binding causes the normal SwiftPM build to fail before running the consumer. `inspect` reports the canonical type, such as `Swift.String`.

An ordinary `swift test` or `swift build` builds the generator and compiles the generated mock with the attached target. Source membership comes from direct Swift targets in the consumer package. The current profile emits a single Swift shard and its index in SwiftPM’s plugin work directory.

Run the checked-in consumer with `swift run --package-path Fixtures/PluginConsumer PluginProbe`. Use `BLUEPRINT_VERIFY_SWIFTPM_PLUGIN=1 python3 scripts/verify.py` for clean-build, incremental and rejection checks. Local checkout installation is verified on Apple Swift 6.4. Separate remote tooling distribution and other native profiles remain open.

The source-built plugin shares the consumer’s SwiftPM graph and requires SwiftSyntax exactly `600.0.1`. If your consumer pins a different SwiftSyntax version, run [standalone generation](#standalone-generation) from the authoring checkout and include the emitted Swift in your test target. The standalone script uses the selected Xcode toolchain’s bundled parser, so the consumer can resolve the runtime and its own SwiftSyntax pin independently.

### Inspect a generation request

Use `inspect` to review a SwiftPM-style request before generating its mock shard and index. Pass the same configuration, source input set and output directory you would give generation.

```sh
bash scripts/generate.sh inspect \
  --config Fixtures/PluginConsumer/blueprint-mocking.json \
  --output Fixtures/PluginConsumer/.build/inspection-example \
  --input-set-id 1 \
  --source PluginDomain Fixtures/PluginConsumer/Sources/PluginDomain/Lookup.swift \
  --format json
```

The report includes the resolved selections and declaration locations, supplied sources, planned output files and supported analysis. Paths under the configuration directory appear relative to it. The command runs generation validation and leaves the project sources and generation output directory untouched.

Use `verify-generated` with the configuration, output directory, input-set ID and source arguments to check the existing shard and index. Exit 0 confirms both files match the plan. Exit 3 reports each missing or changed path with `BPM003`. The check preserves existing files and leaves missing paths absent.

### Local tooling source export

The authoring repository can produce a standalone `blueprint-swift-mocking-tools` source archive. Use the full SHA of a commit that includes the tooling export manifest.

```sh
revision=$(git rev-parse HEAD)
artifact_dir=$(mktemp -d)
archive="$artifact_dir/blueprint-swift-mocking-tools.tar"
python3 scripts/export_tooling.py export "$revision" --output "$archive"
python3 scripts/export_tooling.py verify "$revision" --archive "$archive"
python3 scripts/verify_tooling_install.py "$revision" --archive "$archive" \
  --swift-syntax-mirror "$prepared_swift_syntax_mirror" \
  --evidence-dir "$artifact_dir/evidence"
```

Set `prepared_swift_syntax_mirror` to a local bare Git mirror containing the SwiftSyntax tag and commit in the export manifest. The install check resolves separate tooling and runtime packages by exact Git revision using local Git transport. It verifies the prepared SwiftSyntax pin and the runtime-only dependency graph. The check covers package resolution. Building the exported tool and qualifying public distribution and other hosts remain separate gates.

### Standalone generation

The generated source is included so the consumer can build directly. Regenerate it with:

```sh
bash scripts/generate.sh \
  --input Fixtures/ProtocolConsumer/Sources/ConsumerDomain/UserRepository.swift \
  --module ConsumerDomain --protocol UserRepository \
  --output Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/UserRepositoryMock.swift
```

For a public `Sendable` protocol that inherits other protocols, pass their files explicitly using repeated `--source MODULE FILE` arguments. Keep `--input` pointed at the selected protocol’s file.

```sh
bash scripts/generate.sh \
  --input Sources/AppDomain/Directory.swift --module AppDomain \
  --protocol Directory --output Tests/AppTests/DirectoryMock.swift \
  --source AppDomain Sources/AppDomain/Reading.swift \
  --source AppDomain Sources/AppDomain/Writing.swift \
  --source AppDomain Sources/AppDomain/DirectoryRoot.swift
```

The generator follows transitive parents in the supplied sources and emits a shared diamond requirement once. Same-module parents may use their bare names. For a parent in another module, add an unconditional plain import in the declaring file, spell the parent as `ParentModule.ParentProtocol` and supply its files under `--source ParentModule`. The resolver diagnoses module qualifiers shadowed by supplied imports. Inherited call reports retain the declaring module, file and line.

Parents must be public, top-level, nongeneric protocols. Across modules, ordinary instance methods may use explicitly qualified `Swift.Bool`, `Swift.Int` and `Swift.String`, or an explicitly bound associated type visible to the declaring protocol. Methods may omit the return type. Inherited methods from other modules need distinct member names. These requests use ordinary mocks. Forwarding, projections and generic specializations are outside the cross-module profile. The SwiftPM configuration entry uses the same resolver with both modules supplied as source inputs. In the build plugin, the attached target must directly depend on all participating source targets. Conditional and actor-isolated parents, imported module interfaces, qualified nominal payloads and typed errors in foreign requirements are outside this profile.

To bind a primary or ordinary associated type, pass `--bind-associated-type Name=Type` to standalone generation. The generated mock exposes the bound name as a public type alias and uses the concrete type in its stubs and verification API. Supply each inherited declaration's source under its declaring module. The [qualified-parent fixture](Fixtures/ProtocolConsumer/Sources/ConsumerDomain/AssociatedDirectoryFromDependency.swift) binds a primary associated type declared in a dependency.

```sh
bash scripts/generate.sh \
  --input Fixtures/ProtocolConsumer/Sources/ConsumerDomain/AssociatedDirectory.swift \
  --module ConsumerDomain --protocol AssociatedDirectory \
  --output Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/AssociatedDirectoryMock.swift \
  --source ConsumerDomain Fixtures/ProtocolConsumer/Sources/ConsumerDomain/AssociatedDirectoryBase.swift \
  --bind-associated-type Element=String
```

This profile supports ordinary instance methods on `Sendable` protocols, with `Swift.Bool`, `Swift.Int`, or `Swift.String` bindings and optional `Sendable` constraints. Bind each associated type once. Overloads need distinct argument labels. General dependent constraints, defaults and associated types from compiler-provided interfaces remain open.

A supplied parent with one primary associated type can fix the witness in the inheritance clause. For example, `ParentDomain.BoundParent<Swift.Int>` sets `Element` to `Swift.Int`. The inheritance clause accepts `Swift.Bool`, `Swift.Int` or `Swift.String` in this profile. An explicit CLI or configuration binding may repeat the same type and must agree with the source constraint.

For a dependent iterator, declare `associatedtype Iterator: Swift.IteratorProtocol & Swift.Sendable where Iterator.Element == Element`. Bind `Iterator` to a module-qualified struct from the selected source module, such as `--bind-associated-type Iterator=ConsumerDomain.IntCursor`. Supply its source file. The public nongeneric struct must directly declare both conformances and a public scalar `Element` type alias. The generator checks that alias against the resolved `Element` before writing the mock. The [iterator fixture](Fixtures/ProtocolConsumer/Sources/ConsumerDomain/IntSequence.swift) gets its scalar binding from a parameterized parent.

For a simple `#if FLAG` with an optional `#else` inside a protocol, pass `--source-condition MODULE FLAG true` or `--source-condition MODULE FLAG false`. Use the module that declares the requirement. Repeat the option for every condition reached during generation. Both standalone generation and configured `generate`, `inspect` and `verify-generated` accept it. The mock emits the selected requirements. Automatic SwiftPM plugin discovery of the effective compiler conditions remains open.

For supported Sendable methods, add `--project 'fetch(id:)'` and any other `--project` selectors to generate a separate `<Protocol>ProjectedMock`. Synchronous nonthrowing and async-throwing methods can opt in. A selector uses the declaration's argument labels, including `_:` for unlabeled arguments. If overloads share the same labels, use the canonical endpoint ID listed in the diagnostic.

Supply an `InvocationProjection` for each selected initializer argument `projectionN`, then read `mock.verify.historyN` for its typed history. The generated index follows canonical endpoint order. For projected String fields, `mock.verify.stableHistoryN` accepts `matchingArgument:` or `matchingResult:` and a session-clock window. Unselected methods retain the ordinary verification descriptors, and stubbing uses the same typed setup for all methods.

To install a tested development revision from GitHub, use a URL dependency and the repository identity in your test target's product declaration:

```swift
.package(
    url: "https://github.com/trianstudios/blueprint-swift-mocking-framework.git",
    revision: "568502aaa8ecc8c449393dd247a8afd77ecd35cf"
)
.product(name: "BluepringMockingFramework", package: "blueprint-swift-mocking-framework")
```

Run `python3 scripts/verify_remote_install.py <commit>` to verify RuntimeOnly, Swift Testing, and XCTest from the public URL. It exports the fixtures at that commit and records their resolved pins in an ignored `.build/remote-install/` report. After an approved release tag is available, add `--version <exact-semver>` to verify the tag resolves to the supplied commit.

For generated and direct Sendable synchronous or async-throwing stubs, create an `ArgumentCaptor` with the same `MockSession` as the mock and attach it using `.capturing(into:projecting:)` before configuring the answer. A synchronous winner projects once before its answer. An async-throwing winner projects after it reserves an answer, so exhausted sequences publish no capture. Captures are returned in admission order. A reset clears the live captor and any previously read capture array keeps its values.

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

The generator accepts top-level public protocols in two profiles: a Sendable protocol with supported inherited requirements, or an `@MainActor` protocol without inheritance. Both support zero or more parameters and simple named types, including nested optionals, arrays, and dictionaries. A Sendable mock requires Sendable inputs and results. MainActor mocks can retain actor-local, non-Sendable references. Methods support sync, sync throws, async, async throws, Void, Never and named error types. Overloads may differ by argument label or input type. A multi-argument answer receives an ordered tuple, while setup and verification accept one typed matcher per argument. SwiftParser and SwiftSyntax come from the installed Xcode toolchain, and the verification suite compiles each generated conformance.

Protocol properties expose separate `get_<name>()` and `set_<name>(matcher)` descriptors for stubbing and verification. Read-only getters retain their async and throwing effects. Ordinary property stubs keep getter results independent from setter calls. Opt into last-assigned-value behavior with `stubs.store_<name>(initialValue:)`. Getter and setter verification stay separate.

Concrete instance subscripts expose `get_subscript` and, when writable, `set_subscript` descriptors. Pass one matcher per index and a separate `newValue:` matcher for a setter. A single parameter name in a subscript declaration denotes an unlabeled index. Swift's computed read-modify-write uses the generated getter and setter independently. Read-only subscripts preserve async and throwing getter effects, including named errors and `throws(Never)`. Variadic indices keep `Element...` in the witness and reach each descriptor as a typed `[Element]` in call order.

For a Sendable protocol with a synchronous, read-only generic subscript, select each concrete index type with `--specialize-subscript 'get_subscript(_:)=Int'`. Use `stubs.get_subscript(.any, as: Int.self)` and `mock.verify.get_subscript(.any, as: Int.self)` for that specialization. This profile supports one generic index, simple inline constraints, and either a fixed value result or a result of the index type. Each selected type gets separate rules and typed history. Session events share the declaration ID and expose the concrete type in `endpoint.specialization`. The generic witness reports the requested type and terminates if that type has no selected specialization.

Concrete synchronous static subscripts on Sendable protocols use a generated `TypeScope`. Create one with the mock type's `makeTypeScope(failureReporter:session:_:)` and configure its typed get/set descriptors. Bind it with `scope.withValue { ... }` around calls through the consumer's metatype seam, then assert through `scope.verify`. Child tasks inherit the binding. An unstructured `Task {}` created inside the scope can retain it after the lexical block exits. Finishing the owning session refuses later admissions through the retained binding. Detached tasks must explicitly bind the scope inside the task. A session history reset invalidates existing type scopes. A missing binding emits a standalone diagnostic. A nonthrowing value getter terminates after reporting, and a setter reports and returns.

Variadic instance methods keep `Element...` in the generated witness and pass arguments in call order to typed `[Element]` matchers, answers, and captures. A named failure mapper uses the packed array metatype for the variadic parameter. For call-through, add `--forward-variadic 'sample(_:)'` when generating a Sendable variadic method, then supply `forwarding: .init { $0.sample([Int].self) { entries in provider.sample(entries) } }`. The adapter receives fixed arguments separately from the packed array and preserves the declared effects. Explicit stubs take priority. An exhausted winning sequence retains its failure behavior. Variadic call-through uses an explicit array-taking provider. Swift rejects splatting an array into a variadic call. Select Sendable variadic subscript accessors independently, using `--forward-variadic 'get_subscript(field:_:)' --forward-variadic 'set_subscript(field:_:newValue:)'` for a writable subscript with a labeled field and an unlabeled variadic index. Pass the typed `newValue:` separately to the setter adapter.

Generate a Sendable or `@MainActor` protocol spy with `--spy` and pass the real conformer as `forwardingTo:` when initializing the mock. An unmatched method or accessor calls the injected conformer with the original arguments and effects. Matching stubs and exhausted winning sequences keep their usual behavior. The supplied target stays fixed after initialization. The spy records one admission and one terminal outcome for each admitted call. Filter verification by `origin: .forwarded` to count actual forwarded outcomes. Sendable spies also expose that origin in the session journal. MainActor spies keep non-Sendable inputs in actor-local history and return results on MainActor. Calls the real conformer makes to itself stay inside it. Direct spies cover supported methods, instance getters, and setters declared `nonmutating set`. A forwarded setter passes the new value to the real conformer. A matching setter stub receives the value instead. Use the separate array-taking provider for Swift variadics. Mutating setters, generic and static requirements, and projected profiles require further support.

Checked Sendable spies also support synchronous methods with a single `inout Int` parameter. Pass the caller's value to the mock with `&` as usual. Real providers and `willAnswer` stubs can change it before returning or throwing a typed error. Pass `after:` to verification to match the final integer in addition to the entry value.

Checked Sendable spies can also forward a final, unary nonescaping callback on a synchronous nonthrowing method. A `willAnswer` stub receives the ordinary input and callback separately. Stubbing and verification match the ordinary arguments, and the journal stores only those arguments. Swift enforces the callback lifetime at the witness and answer boundaries. Escaping, effectful and explicitly isolated callbacks require another profile.

Set `maximumAsyncThrowingForwardingDepth:` to a positive integer when initializing a checked Sendable spy to bound recursive async-throwing call-through. Only active real forwarding hops count. A matching stub still wins at the limit. A blocked call reports once and follows the endpoint’s missing-call policy. A configured typed failure mapping turns the rejection into a declared error. Inherited tasks participate while their forwarding ancestry is active. Detached work starts with an independent path. This limit bounds opaque reentry through a real provider.

Checked async-throwing spies can declare a typed forwarding link. Configure an endpoint with `forwardingLinks: .init { $0.fetch(Int.self, through: link) }`, then bind the link with `link.bind(to: target.forwardingTargets.fetch(Int.self))`. The link binds once and holds its target weakly. A configured link takes precedence over `forwardingTo:` for that endpoint. Matching stubs keep first choice. If an endpoint would follow a link twice on the same path, the repeated call reports once and applies its missing-call policy. Each call keeps its own admission and outcome. A call from an opaque real provider starts a new structural path and can still participate in the configured depth limit.

The runtime supports typed equality, identity, optional, collection, string, numeric, custom and short-circuit logical matchers, last-registration-wins rules, immutable setup plans, return/answer stubs, typed async errors, admission/returned/threw count queries, and exact, minimum, maximum and inclusive-range counts. Use `.and`, `.or` and `.not()` to compose count predicates. An impossible combination produces a contradiction diagnostic. Use `Matcher.projecting(_:matching:)` to match typed enum payloads. Its extractor can reject a case before evaluating the payload matcher. Each endpoint has its own typed storage and append-only journal. No Any result casting, process-global registry, detached answer task, or unchecked Sendable conformance is used. User matchers, answers, and reporters execute outside journal synchronization.

Unstubbed nonthrowing Void calls report and return. An unstubbed value call reports before termination unless the endpoint has an explicit typed fallback. Methods declared `throws(Never)` retain that signature and can be called without `try`. An unstubbed ordinary throwing method reports the issue and throws `UnexpectedInvocationError`. Async typed-throwing endpoints optionally accept an explicit mapping to their declared failure type; catching that error does not suppress reporting. Configure generated mappings by endpoint, for example `failureMappings: .init { $0.fetchUser(id: String.self) { _ in .offline } }`. Index and argument metatypes identify overloads. Migrate numbered `failureMappingN:` arguments to the named configuration when regenerating. Typed verification reports an endpoint-local snapshot watermark and the caller's source location.

The runtime manifest declares macOS 13, iOS 16, tvOS 16, watchOS 9 and visionOS 1. The runtime uses Synchronization.Mutex where the OS supports it and NSLock on older Apple targets. The verification suite runs on Apple Swift 6.4 in Swift 6 language mode on arm64 macOS 27. Run `python3 scripts/verify_apple_deployment.py` with all five SDKs installed to link the runtime at the deployment floors, including both macOS architectures. The optional `--pre-mutex-ios-simulator DEVICE` check exercises the fallback lock and typed answers on an existing iOS 16 or 17 simulator. Execution on the exact older Apple releases still requires native testing.

Direct users of the checked Sendable `AsyncThrowingEndpoint` can publish a new configuration with `replaceConfiguration(_:)`. Each call keeps the plan and revision it received at admission through completion. The generated mock API still configures each mock during initialization.

Sendable async-throwing stubs support `willSequence(.throwing(.offline), .returning(value), policy: .repeatLast)`. A sequence can also use typed `.answering` steps. The default finite policy reports exhaustion through the endpoint's configured failure behavior. Use `.repeatLast` or `.cycle` to continue after the final step. Each installed revision has its own cursor, and a step stays reserved if its answer throws or is cancelled.

Pass the same `MockSession` to multiple generated Sendable mocks to inspect a shared, ordered timeline with `session.snapshot()`. Each mock keeps its own typed history and has its own identity. A generated Sendable mock creates a private session when none is supplied.

Use `try session.resetHistory()` to clear history once all calls have completed, or `try session.resetHistory(.detachActive)` to start a fresh epoch while old calls finish. Detachment keeps the old epoch's event metadata. Typed arguments are discarded from endpoint history, and old calls do not update the new epoch's counts. Reset keeps configured rules and stored property values. Build a new verification descriptor after reset. An old descriptor fails as stale and does not evaluate its matcher.

Use `ProjectedSyncEndpoint` or `ProjectedAsyncThrowingEndpoint` with an `InvocationProjection(argument:result:)` to retain selected Sendable fields. A thrown call records an unavailable result. A returned optional nil remains a valid input to the result projection. Supply value snapshots such as identifiers or redacted summaries when history must survive changes to an object. `projectedHistory()` returns the endpoint's current-epoch records. A field stays pending while its projection runs, and a result publishes together with its returned phase. Verify a projected history with `verify(_:matchingArgument:phase:)` or `verify(_:matchingResult:phase:)`. Complete successful assertions return typed captures in admission order. Pending or unavailable fields are reported when they prevent a complete capture. Use `WeakProjectedReference` when you need to inspect an object's identity while it is alive. Its live `object` read can return nil after deallocation, while the capture keeps its invocation metadata.

Use `session.checkpoint()` and `try session.events(since: checkpoint)` to read the events added after a position. This includes completions of calls admitted before the checkpoint. A foreign session or a reset epoch produces a typed error.

Use `session.withContext { ... }` to bind an epoch to the current lexical scope. Structured child tasks inherit the token. Detached work and callbacks can capture `session.contextHandle` and rebind it explicitly with `session.withContext(handle) { ... }`. Validation rejects missing, foreign and stale context. Keep passing `session:` explicitly when constructing instance mocks.

Call `session.snapshot().matchOrder(_:mode:phase:)` to read cross-mock order by mock and endpoint IDs. Relative mode allows intervening events. Strict mode requires consecutive matches in the selected phase. A selector from a different session is rejected. Use `session.snapshot().matchCompletion(of:beforeStartOf:phase:)` to find a completed invocation followed by a distinct invocation's admission in the same epoch.

Await `session.waitForQuiescence(until: deadline, clock: clock)` to observe a snapshot with no active calls, including calls in detached epochs. Waiting is cancellable, and the deadline is exclusive. Producers can admit new calls after the snapshot.

Use `try endpoint.replaceConfigurationIfQuiescent(plan)` on a direct `AsyncThrowingEndpoint` when replacing its stubs requires an idle session. The idle check and publication are atomic. The check includes active calls from earlier epochs. It throws `QuiescentConfigurationError` for active calls, a finished session, or a stale epoch-bound scope.

Use `try await endpoint.replaceConfigurationWhenQuiescent(plan, within: .seconds(2))` to let existing calls finish. It publishes before the next admission at an eligible idle boundary. The deadline uses the session clock and is exclusive. A timeout or cancellation before publication leaves the current plan intact. Request the update outside calls the update needs to drain.

After your tasks have finished, call `try session.finishIfQuiescent()` to close admission and preserve the final timeline. Active calls cause a typed error. A later mock call reports through its original endpoint reporter and uses the endpoint's legal fallback, error mapping or termination behavior. It leaves final history unchanged. This operation does not join application tasks.

Share an `OrphanFailureBuffer` with `MockSession(orphanFailures: buffer)` to collect rejected calls from closed sessions. In an active Swift Testing run, import `BlueprintMockingTesting` and call `await FailureReporter.flushSwiftTestingOrphans(buffer)`. The flush reports the batch at run level and includes original session and source information. Join known producers before the final flush. Custom harnesses can claim a batch with `buffer.drain()` and use its dropped count when determining the run result.

On macOS XCTest, import `BlueprintMockingXCTest` and call `try FailureReporter.flushXCTestOrphans(buffer, in: suiteRun)` on the runner’s path for an active suite. Pass the suite run explicitly, for example from an `XCTestObservation` hook. The flush records issues at suite level. An inactive suite throws before it claims the buffer.

Use `try session.discardEvents(through: checkpoint)` to discard a current epoch's session metadata prefix. A checkpoint that misses a discarded event reports unavailable history. A gap in global ordinals alone is valid because another epoch can receive events. Endpoint argument histories are separate.

Use `try session.verifyNoInteractions(in: .session)` to check for admissions through the current snapshot, or pass `.mock(mockID)` to check one mock. Use `since:` to start after a checkpoint and `ignoring:` to exclude explicit mock-and-endpoint pairs. A retained admission disproves absence. A pruned prefix can leave the result unavailable.

Create an epoch-scoped verification scope with `session.consumptionScope(named:)`. Use `try session.consume(.earliest(1), for: selector, in: scope)` to claim one matching admission, or `.all` to claim every match in the snapshot. A concurrent change to the same scope can cause a conflict. A failed claim leaves the scope unchanged. Use `try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope)` to check for unclaimed admissions. Ordinary interaction and typed count checks still include claimed calls. Projected endpoints also accept `consume(_:matchingArgument:phase:in:)`. The resulting bundle contains the claimed IDs and the typed records selected from the same snapshot. Pending projections can prevent a claim.

For live observation, retain `session.observeChanges()`, then use its notifications as wake-ups. Read `try session.replay(since: checkpoint)` after a wake and use the returned checkpoint for the next read. Replay returns all retained events through that position, so coalesced wakes preserve intermediate transitions. Cancel the observation when finished.

Use `session.eventually(_:for:phase:within:)` to find the first committed metadata count that satisfies the predicate before a session-clock deadline. A late wake still sees a qualifying pre-deadline prefix, even if a later call invalidates it. Use the `until:clock:` overload to supply a Swift clock and bound when the observer must see a qualifying prefix. Both overloads throw when unavailability of history prevents evaluating the query.

Use `session.until(_:for:phase:for:)` to require a count to hold throughout an interval, or `session.stable(_:for:phase:for:within:)` to wait for an uninterrupted satisfying window. Both count committed events by mock, endpoint, and phase. Events stamped at the interval's ending boundary are outside that interval. Time defaults to a monotonic clock. Use `MockSession(clock: .manual)` and `try session.advanceClock(by:)` for deterministic tests. Projected Sendable endpoints with String argument snapshots also support `stable(_:matchingArgument:for:within:)`. A pending admission interrupts the candidate, and publication can start a fresh window. The assertion reports incomplete history when unsettled data prevents the proof at the deadline. The `matchingResult` overload counts literal String result snapshots. An in-flight result stays pending until terminal publication. A typed throw settles as a known non-return.

For the Ubuntu 24.04 arm64 runtime profile, run `bash scripts/verify_linux_runtime.sh --help` to prefetch the pinned Swift image, then `bash scripts/verify_linux_runtime.sh` to test a committed revision with networking disabled. The workflow exercises the runtime, archived generated mocks, both reporters, and runtime-only linkage. Linux code generation, Ubuntu 22.04, Linux x86_64 and Windows still require verification.

The MainActor mock keeps setup, matchers, answers, invocation history, and verification on MainActor. A matcher can observe actor-local state, and an answer may return an actor-local reference. History retains those references and evaluates matchers against their state at verification time. The sample includes a consumer workflow and checks that illegal cross-actor access fails compilation. Custom global actors, Actor-constrained protocols, projections, advanced history and sessions, additional declaration families, plugins, migration and release certification remain roadmap work.

See the [implementation evidence](Docs/Implementation-Evidence.md) for the verified scope and the next slice. The [contribution guide](CONTRIBUTING.md) explains the TDD workflow and how to submit a milestone.

This repository is licensed under the [MIT License](LICENSE).
