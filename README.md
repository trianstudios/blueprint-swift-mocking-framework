# Blueprint Mocking

Blueprint Mocking generates typed Swift test doubles. The public prototype supports generated Sendable and MainActor protocol mocks. The [acceptance roadmap](Docs/Acceptance-Status.csv) tracks the 125 contracts from architecture edition 1.0.

The first implemented slice generates a checked Sendable protocol mock, configures typed answers, injects it into a real service, and verifies calls. Configuration and verification use descriptors; neither executes a production requirement. Runtime, generation, and runner reporting have separate source boundaries.

Run from this directory on the tested Xcode toolchain:

```sh
python3 scripts/verify.py
```

That entry point regenerates the consumer mock, runs runtime and consumer tests, executes the example, checks compiler and generator rejections, runs deliberate failures in child processes, and checks runtime-only linkage. It writes local results and the toolchain profile to the ignored `Evidence/` directory. The profile records the source revision when the checkout is clean and unchanged across the run. Hashes bind the profile to the results and each result to its log.

To run the SYS-008 evaluator checks without building Swift targets, use `python3 scripts/verify.py --release-checks-only` from a clean checkout. It records each suite’s log and digest along with the exact source revision in `Evidence/release-checks/release-checks.json`. Set `BLUEPRINT_EVIDENCE_DIRECTORY` to write the scoped report and logs to a dedicated directory. [Release profile plan](Docs/Release-Profile-Plan.md)

For the ordinary SwiftPM entry points after generation:

```sh
swift test
swift test --package-path Fixtures/ProtocolConsumer
swift run --package-path Fixtures/ProtocolConsumer consumer-demo
```

### Testing final classes, value types, and free functions

Give the consumer a protocol for each operation it needs and write a live adapter that calls the existing dependency. Generate the test double for the protocol. Inject either the live adapter or the generated mock through the same initializer. The production target needs only the protocol and live adapter.

The checkout quote example shows all three forms in one service.

| Existing dependency | Injectable protocol | Live adapter |
| --- | --- | --- |
| Final class `ProductCatalog` | `CatalogPricing` | `ProductCatalogAdapter` |
| Struct `BasketCredit` | `BasketDiscount` | `BasketCreditAdapter` |
| Free function `canonicalSKU` | `SKUFormatting` | `CanonicalSKUAdapter` |

Select `CatalogPricing`, `BasketDiscount`, and `SKUFormatting` when regenerating the mocks. Mock history begins at the generated protocol witnesses. Direct calls to the catalog, credit value, or function stay outside that history. For a dependency with restricted access, put the live adapter where Swift permits the call and inject its protocol at the consumer boundary. [Adapters and service](Fixtures/ProtocolConsumer/Sources/ConsumerDomain/CheckoutAdapters.swift) · [Consumer tests](Fixtures/ProtocolConsumer/Tests/ConsumerTests/DependencyAdapterTests.swift)

```sh
swift test --package-path Fixtures/ProtocolConsumer --filter SYS005
```

### Generate a facade for a final SDK class

For a frozen Swift SDK on macOS, the `facade` command can read a validated public interface and select one public synchronous instance method taking and returning `Int` on a directly Sendable final class.

```sh
bash scripts/generate.sh facade --interface FrozenSDK FrozenSDK.swiftinterface \
  --importer-context importer.json --class FrozenQuoteSDK --method 'quote(value:)' \
  --output FrozenQuoteSDKFacade.swift
```

Inject the generated facade protocol into your caller. Supply the original SDK instance to its live adapter or configure the generated mock with typed stubs. The live adapter calls the SDK's public method. Direct SDK calls use their usual path.

### Selecting a return-only overload

For a pair of ordinary Sendable synchronous nonthrowing methods with the same arguments and `Int` and `String` results, select the result type in the generated setup and verification. For example, use `stubs.lookup(id: .equal("sku"), returning: Int.self).willReturn(42)` and `mock.verify.lookup(id: .equal("sku"), returning: Int.self).wasCalled(.once)`. Calls through the protocol select a witness using the result type in the caller. [Consumer fixture](Fixtures/ProtocolConsumer/Tests/ConsumerTests/ReturnOnlyOverloadTests.swift)

### Keyed storage for generated subscripts

Use `StoredSubscript<Key, Value>` with a Sendable, Hashable key and a Sendable value. Set an initial value for each key you need, then connect the generated getter and setter to the same store.

```swift
let scores = StoredSubscript<Int, Int>()
scores.set(10, for: 7)
let mock = WritableSpyDirectoryMock(failureReporter: .swiftTesting) { stubs in
    stubs.get_subscript(slot: .any).willAnswer { slot in scores.get(slot) ?? 0 }
    stubs.set_subscript(slot: .any, newValue: .any).willAnswer { arguments in
        scores.set(arguments.1, for: arguments.0)
    }
}
```

Each read, write, or removal is atomic. Getter and setter history stays separate, including when Swift calls both during a compound assignment. [Consumer fixture](Fixtures/ProtocolConsumer/Tests/ConsumerTests/StoredSubscriptTests.swift)

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

Create `blueprint-mocking.json` at the consumer package root. Use the Swift module name and select top-level public protocols that the generator supports. The selection and supplemental source manifest files each have a 1 MiB limit, including whitespace.

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

For a supported generic method, add `genericMethodSpecializations` to its protocol selection. Configure each required concrete type explicitly.

```json
"genericMethodSpecializations": [
  {"selector": "transform(_:)", "type": "Int"},
  {"selector": "transform(_:)", "type": "String"}
]
```

The configuration uses the same typed descriptors as `--specialize-method`. In `inspect`, the declaration ID stays the same across specializations. Each specialized row includes its own `specialization` value, such as `Swift.Int`.

An ordinary `swift test` or `swift build` builds the generator and compiles the generated mock with the attached target. Source membership comes from direct Swift targets in the consumer package. The current profile emits a single Swift shard and its index in SwiftPM’s plugin work directory.

Configured generation validates the declared Swift source paths and records normalized membership in the index independently of the caller’s input-set ID. Adding or removing an unrelated listed source updates the index when the generated Swift is identical.

To index a source outside SwiftPM target membership, create `blueprint-mocking.external-sources.json` beside the generation configuration. Use an existing direct module and a package-relative Swift file.

```json
{
  "schemaVersion": 1,
  "mode": "tracked",
  "sources": [{"module": "AppDomain", "path": "External Sources/RepositoryContext.swift"}]
}
```

Keep the manifest in place and edit its rows when adding or removing supplemental sources. SwiftPM invalidates this route when the manifest changes. For edits to a supplemental source, update the manifest as part of the change or invoke configured generation explicitly. Use normal target membership when SwiftPM should track the source file directly.

Run the checked-in consumer with `swift run --package-path Fixtures/PluginConsumer PluginProbe`. Use `BLUEPRINT_VERIFY_SWIFTPM_PLUGIN=1 python3 scripts/verify.py` for clean-build, incremental and rejection checks. Local checkout installation is verified on Apple Swift 6.4. Separate remote tooling distribution and other native profiles remain open.

The source-built plugin shares the consumer’s SwiftPM graph and requires SwiftSyntax exactly `600.0.1`. If your consumer pins a different SwiftSyntax version, run [standalone generation](#standalone-generation) from the authoring checkout and include the emitted Swift in your test target. The standalone script uses the selected Xcode toolchain’s bundled parser, so the consumer can resolve the runtime and its own SwiftSyntax pin independently.

The configured CLI accepts one compatible public macOS Swift 6 interface for a Sendable protocol with synchronous nonthrowing scalar methods. It resolves public inherited requirements declared in that interface under the same module.

```sh
bash scripts/generate.sh generate --config blueprint-mocking.json --output Generated \
  --input-set-id a003 --interface InterfaceDomain InterfaceDomain.swiftinterface \
  --importer-context importer.json
```

The schema-1 importer context declares compiler identity, target triple, language mode, default actor isolation, feature lists, Objective-C interop and the SDK if supplied. See the [native fixture](scripts/verify_imported_interface.py) for the exact context fields. Use the same flags with `inspect` and `verify-generated`. `inspect` records producer context unavailable from the header. A context mismatch emits `BPM005` and exits 4 before replacing output.

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

The report includes the resolved selections, supplied sources, planned output files and supported analysis. Each selected declaration lists the generated endpoint IDs and the module, file, line and column of each requirement, including requirements inherited from indexed sources. Paths under the configuration directory appear relative to it. The command runs generation validation and leaves the project sources and generation output directory untouched.

Use `verify-generated` with the configuration, output directory, input-set ID and source arguments to check the existing shard and index. Exit 0 confirms both files match the plan. Exit 3 reports each missing or changed path with `BPM003`. The check preserves existing files and leaves missing paths absent. A retained recovery journal exits 1 with `BPM004`. Rerun configured generation with valid inputs to recover the pair. Existing generated destinations must retain the Blueprint Mocking provenance header. A hand-authored file at either reserved name is reported before any generated file is replaced. If an interrupted build left a journal, recovery verifies the recorded publication state before it writes.

### Xcode build-phase generation

A sandboxed Xcode Run Script phase can generate and compile mocks in a target's DerivedData intermediates. Use explicit input and output file lists for one supplied Swift source module. The installation guide includes the reviewed project patch and the native macOS fixture. [Xcode build-phase guide](Docs/Xcode-Build-Phase.md)

### SwiftPM command plugins

With the tooling package declared as a dependency, `swift package plugin --list` lists the Blueprint Mocking command verbs. Pass the same configuration, output and source arguments to both verbs.

```sh
swift package blueprint-mocking-read inspect --config blueprint-mocking.json \
  --output Generated --input-set-id 1 --source AppDomain Sources/AppDomain/Repository.swift --format json
swift package --allow-writing-to-package-directory blueprint-mocking-generate --config blueprint-mocking.json \
  --output Generated --input-set-id 1 --source AppDomain Sources/AppDomain/Repository.swift
```

Use `verify-generated` with `blueprint-mocking-read` to check an existing pair without package-write permission. Generation takes a fresh package-relative directory under an existing parent. The wrapper reports the canonical invocation. For automation that needs a pure JSON stream, use direct CLI inspection.

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

On macOS, set `BLUEPRINT_VERIFY_TOOLING_ARCHIVE_MIRROR` to the prepared SwiftSyntax mirror when running `scripts/verify.py` from a clean checkout. The tooling archive check resolves a fresh verified extraction and confirms that the installer rejects altered and substituted archives before Swift selection or evidence changes.

### Offline runtime qualification on macOS

Run the runtime-only SwiftPM consumer from a prepared bare Git mirror containing the selected commit.

```sh
revision=$(git rev-parse HEAD)
python3 scripts/verify_offline_runtime.py "$revision" \
  --runtime-mirror "$prepared_runtime_mirror" \
  --evidence-dir "$artifact_dir/offline-runtime"
```

The verifier checks the bare Git mirror's object integrity before changing evidence or invoking SwiftPM. It isolates SwiftPM caches and mirror configuration, confirms OS-level network denial, then resolves, builds and runs the typed consumer. It checks Mach-O libraries and static link inputs for the runtime-only dependency boundary. Set `BLUEPRINT_VERIFY_OFFLINE_RUNTIME_MIRROR` to the same mirror path when running `scripts/verify.py` from a clean checkout to collect the offline install, corrupt-object rejection, and configured generation checks with the rest of the prototype evidence. The generation check compares the shard and index against a normal run and builds the independent consumer under the same network policy using the Xcode-bundled parser.

### Report-only runtime performance on macOS

From a clean checkout, use Python 3.12 or newer and the selected Xcode Swift toolchain.

```sh
python3 scripts/verify_runtime_performance.py --evidence-dir .build/runtime-performance-local
```

Choose an empty evidence directory, either ignored by Git or outside the checkout. The verifier archives the exact commit, builds the dependency-free runtime and its SwiftPM consumer in checked release optimization with networking denied, and discards the isolated build state after measurement. The report records source and executable hashes, the selected hardware and toolchain, and the measured latency, concurrent admission, live malloc heap and teardown results.

The local report shows how the latency samples compare with the published 2 µs target. Release approval requires the declared reference hardware, compatible baseline comparisons and the rest of D4.3, including generation, build, lock-wait and cancellation evidence.

### Optional source facts cache

Configured `generate` can take `--source-facts-cache DIRECTORY` with the tool that links Xcode's bundled parser. Choose a dedicated owner-private directory outside the generated output directory. The cache skips indexing regular UTF-8 Swift source files when the same bytes were previously parsed and found to contain only top-level free functions or no declarations. The generator still opens and hashes the current source and indexes participating declarations normally. A malformed, oversize, or incompatible cache record triggers parsing again. Cache use is optional and does not require a network connection.

The cache keys these limited facts to the exact executable and parser library files from the selected Xcode toolchain. Keep the toolchain installed at the same location and stable while generating. Each process reads the tool and parser identities before it can reuse a fact. [Implementation evidence](Docs/Implementation-Evidence.md#persistent-configured-source-facts)

### Prepared parser parity

Run this on the prepared macOS host after independently building the bundled generator using `scripts/generate.sh` and the packaged `blueprint-mocking` product using the native SwiftPM debug build system. Use the same authoring revision, selected Xcode `swiftc` and macOS SDK for both. The SwiftPM build comes from `Packages/Tooling` in an exact authoring checkout and resolves the pinned SwiftSyntax 600.0.1 source. Retain its unstripped executable, scratch directory with `checkouts/swift-syntax` and object files, `Package.resolved`, and `blueprint-mocking.product/Objects.LinkFileList` next to the executable.

Use one JSON receipt from each trusted build, with these fields.

| Applies to | Receipt fields |
| --- | --- |
| Both builds | `schema` (integer `1`), `route` (`bundled` or `packaged`), `sourceRevision` (full Git SHA), `executableSHA256`, `swiftCompiler` (absolute selected compiler path), `compilerVersion` (trimmed full `swiftc --version` stdout), and `sdk` (absolute selected macOS SDK path). |
| Bundled build | `parserSHA256` with the recorded SHA-256 for each file keyed by `libSwiftParser.dylib` and `libSwiftSyntax.dylib` from the Xcode host library directory. |
| Packaged build | `packageResolvedSHA256` and `linkFileListSHA256` for the retained SwiftPM lockfile and link inputs. |

```sh
python3 scripts/verify_parser_parity.py "$revision" \
  --bundled-tool "$bundled_tool" --bundled-receipt "$bundled_receipt" \
  --packaged-tool "$packaged_tool" --packaged-receipt "$packaged_receipt" \
  --package-checkout "$package_checkout" --package-scratch "$package_scratch" \
  --package-resolved "$package_checkout/Packages/Tooling/Package.resolved" \
  --syntax-checkout "$package_scratch/checkouts/swift-syntax" \
  --evidence-dir "$artifact_dir/parser-parity"
```

The command uses the prepared binaries and produces logs and a parity report after all comparisons pass. Keep the build receipts and report with the originating build records. Release attestation is a separate step.

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

For macOS, a synchronous, nonthrowing, parameterless instance requirement of a public `Sendable` protocol can use `@available(macOS VERSION, *)` and return a public nongeneric struct. Supply the struct's declaration from the same module. The struct can be unannotated or use the same single availability attribute with an introduction no later than the requirement’s. The generated class, including its stubbing and verification APIs, requires the latest introduction among its gated methods. Use the mock inside a matching `#available` guard or an annotated declaration. The [SwiftPM fixture](Fixtures/ProtocolConsumer/Tests/ConsumerTests/AvailabilityTests.swift) shows the typed workflow.

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

The standalone generator accepts one concrete specialization per `--specialize-method 'transform(_:)=Int'` or `--specialize-method 'transform(_:)=String'` option. The selected Sendable protocol declares a synchronous, nonthrowing unary `T -> T` requirement with inline `Hashable & Sendable` constraints. Use `stubs.transform(.any, as: Int.self)` and `mock.verify.transform(.any, as: Int.self)` to select a typed specialization. Each specialization has its own rules and history. A call with a type absent from the generation options reports that concrete type before terminating.

For generic behavior that works for every admissible type, generate with `--generic-provider 'transform(_:)'`. Implement the generated `<Protocol>MockBehavior` protocol and pass it as `genericBehavior:` when initializing the mock. Swift checks the provider against the same generic constraints as the original requirement. Provider calls record the concrete type and outcome in session metadata. Other supported requirements still use their typed stubs. Select either a provider or finite specializations for each generic method.

A standalone generic cache spy supports one direct async nonthrowing lookup with a `Hashable & Sendable` key and an optional primary associated result explicitly bound to `Swift.String`. Select it with `--spy --bind-associated-type Value=Swift.String --generic-provider 'lookup(_:)'`. Supply the real cache as `forwardingTo:`. The optional typed provider returns `.handled(value)` or `.forward`. Use `.handled(nil)` for an intentional cache miss. An absent provider forwards each call. The session records the concrete key type and which calls reached the real cache. [Independent consumer](Fixtures/ProtocolConsumer/Tests/ConsumerTests/GenericActorCacheSpyTests.swift)

For `func echo<each Element: Sendable>(_ values: repeat each Element) -> (repeat each Element)`, select `--generic-provider 'echo(_:)'`. Implement the typed pack method on the generated companion provider. The mock forwards the original values and records an ordered, process-local specialization by element type. The empty pack, a one-element `Void` pack, a tuple argument, and multiple arguments have distinct shapes.

For a direct synchronous Sendable `rethrows` method with unary, nonescaping callbacks declared with untyped `throws`, generate with `--rethrows-provider 'apply(_:)'`. Implement the generated `<Protocol>MockRethrowsBehavior` protocol and pass it as `rethrowsBehavior:` at initialization. The witness passes through the original callback and records its provider call in session metadata. For multiple supported callbacks, select their labels in order, such as `--rethrows-provider 'apply(_:fallback:)'`. A caller can omit `try` when all supplied closures are nonthrowing. Other ordinary methods retain their typed stubs.

The same provider selection supports a direct `async rethrows` requirement whose unary nonescaping callbacks are declared `@Sendable` and `async throws`. Use `await` with a nonthrowing callback and `try await` with a throwing callback. The provider runs outside the session lock and its call stays active while suspended. Ordinary value arguments can appear alongside the callbacks. Use their labels in the selector, such as `apply(prefix:_:fallback:offset:)`. Async ordinary arguments support unshadowed standard `Bool`, `Int` and `String` types.

For a Sendable protocol with a synchronous, read-only generic subscript, select each concrete index type with `--specialize-subscript 'get_subscript(_:)=Int'`. Use `stubs.get_subscript(.any, as: Int.self)` and `mock.verify.get_subscript(.any, as: Int.self)` for that specialization. This profile supports one generic index, simple inline constraints, and either a fixed value result or a result of the index type. Each selected type gets separate rules and typed history. Session events share the declaration ID and expose the concrete type in `endpoint.specialization`. The generic witness reports the requested type and terminates if that type has no selected specialization.

Concrete synchronous static subscripts on Sendable protocols use a generated `TypeScope`. Create one with the mock type's `makeTypeScope(failureReporter:session:_:)` and configure its typed get/set descriptors. Bind it with `scope.withValue { ... }` around calls through the consumer's metatype seam, then assert through `scope.verify`. Child tasks inherit the binding. An unstructured `Task {}` created inside the scope can retain it after the lexical block exits. Finishing the owning session refuses later admissions through the retained binding. Detached tasks must explicitly bind the scope inside the task. A session history reset invalidates existing type scopes. A missing binding emits a standalone diagnostic. A nonthrowing value getter terminates after reporting, and a setter reports and returns.

Variadic instance methods keep `Element...` in the generated witness and pass arguments in call order to typed `[Element]` matchers, answers, and captures. A named failure mapper uses the packed array metatype for the variadic parameter. For call-through, add `--forward-variadic 'sample(_:)'` when generating a Sendable variadic method, then supply `forwarding: .init { $0.sample([Int].self) { entries in provider.sample(entries) } }`. The adapter receives fixed arguments separately from the packed array and preserves the declared effects. Explicit stubs take priority. An exhausted winning sequence retains its failure behavior. Variadic call-through uses an explicit array-taking provider. Swift rejects splatting an array into a variadic call. Select Sendable variadic subscript accessors independently, using `--forward-variadic 'get_subscript(field:_:)' --forward-variadic 'set_subscript(field:_:newValue:)'` for a writable subscript with a labeled field and an unlabeled variadic index. Pass the typed `newValue:` separately to the setter adapter.

Generate a Sendable or `@MainActor` protocol spy with `--spy` and pass the real conformer as `forwardingTo:` when initializing the mock. An unmatched method or accessor calls the injected conformer with the original arguments and effects. Matching stubs and exhausted winning sequences keep their usual behavior. The supplied target stays fixed after initialization. The spy records one admission and one terminal outcome for each admitted call. Filter verification by `origin: .forwarded` to count actual forwarded outcomes. Sendable spies also expose that origin in the session journal. MainActor spies keep non-Sendable inputs in actor-local history and return results on MainActor. Calls the real conformer makes to itself stay inside it. Direct spies cover supported methods, instance getters, and setters declared `nonmutating set`. A forwarded setter passes the new value to the real conformer. A matching setter stub receives the value instead. Use the separate array-taking provider for Swift variadics. Mutating setters, generic and static requirements, and projected profiles require further support.

Ordinary Sendable protocol mocks support same-module synchronous methods with a single `inout Swift.Int` parameter. Checked Sendable spies also accept `inout Int`. Pass the caller’s value with `&`. A `willAnswer` stub can mutate it before returning or throwing a typed error, and a spy’s real provider can do the same. Pass `after:` to verification to match the final integer in addition to the entry value.

Ordinary Sendable mocks and checked spies support one final unary nonescaping callback on a synchronous, nonthrowing instance method. A `willAnswer` stub receives the ordinary input and can invoke the original callback while the witness is active. A `willReturn` stub skips the callback. Stubbing, verification, and call history use only the ordinary arguments. Swift enforces the callback lifetime at the answer boundary. A checked spy can also pass the callback to its real provider.

For a synchronous, nonthrowing Sendable protocol method with one final nonescaping `@autoclosure`, opt in with `--lazy-autoclosure 'choose(id:fallback:)'`. Match, return a stubbed value or verify using the ordinary arguments. A typed `willAnswer { input, evaluate in ... }` lets you call `evaluate()` during the invocation. Each explicit evaluation runs the autoclosure on the calling context. Swift rejects attempts to retain the evaluator.

Use `--materialized-autoclosure 'choose(id:fallback:)'` when a matcher needs the fallback value. For supported `Bool`, `Int` and `String` autoclosures, this mode evaluates once after admission and passes the cached value to every candidate matcher, the selected answer and verification. Select the fallback matcher with `fallback: .equal(value)`. An answer receives both `input` and `value`. Value-sensitive verification during evaluation reports incomplete history. A call rejected before admission skips evaluation.

Direct Sendable methods can declare a bare `Self` result on synchronous, nonthrowing requirements with ordinary value inputs. Use the generated final mock type in `willReturn` or a typed `willAnswer` factory. Calls through both generic and existential dependencies verify against the mock that received the call. A protocol constrained to one supplied final class receives an adapter diagnostic.

For a supported open `@Swift.MainActor` root class, use `bash scripts/generate.sh subclass --input BootstrapRenderer.swift --module BootstrapDomain --class BootstrapRenderer --override 'render(_:)' --output BootstrapRendererMock.swift`. The standalone slice accepts one accessible `public` designated initializer and one open synchronous, nonthrowing `Swift.String` method. During `super.init`, the override calls the real method directly. Once configuration is published, it accepts typed stubs, forwards misses to `super`, and records actor-local verification. The generator diagnoses final classes, closed members, unsuitable initializers, and explicit deinitializers.

Count verification failures and composed matcher descriptions are limited to 4,096 UTF-8 bytes. Longer messages keep the count and the beginning of the matcher context, then end with `… [truncated]` at a valid UTF-8 boundary. The renderer uses explicit matcher descriptions and leaves argument payloads untouched.

Call `try session.snapshot().exportTraceJSON(maximumRecords: 128)` to export a versioned metadata trace. The limit accepts 0 through 256 records. Invocations and cancellation requests share the budget, ordered by recorded session ordinal. Runtime pruning and export omissions have separate boundaries. The trace includes developer-supplied endpoint labels clipped to 96 UTF-8 bytes and marks specializations with a Boolean. Payloads are omitted. The encoded size is bounded by 1,024 bytes plus 1,024 per exported record.

A direct checked Sendable protocol method can take one `isolated` parameter of a public concrete actor declared in the same module. The synchronous typed `willAnswer` closure receives the original actor with isolation preserved. Setup and verification use ordinary Sendable matchers, including actor identity. Use `await` from outside the actor. This slice supports nonthrowing methods returning `Int`, `Bool`, or `String`.

A synchronous nonthrowing method can register a unary `@escaping @isolated(any) @Sendable (Int) -> String` callback. Use `IsolatedAnyEscapingCallbackCaptor` to retain the callback and await its replay. It runs on the actor captured by the original function. The captor and generated mock require macOS 15, iOS and tvOS 18, watchOS 11, or visionOS 2.

For a private dependency, put the adapter in the owning declaration or a same-file extension and inject its protocol into the caller. The [fee-pricing fixture](Fixtures/ProtocolConsumer/Sources/ConsumerDomain/PrivateFeePricingOwner.swift) shows the live adapter and its mockable seam. Selecting a private or fileprivate method for subclass generation produces an owner-scope diagnostic.

For a legacy static dependency with no way to pass test context, launch one isolated child process per test request. Within that process, bind a typed `LegacyProcessRegistry` using `withScope` and resolve the legacy dependency with `current()`. Concurrent bindings in one registry are rejected. Join callers that might perform another lookup before opening a replacement scope. The POSIX harness in `scripts/legacy_process.py` checks a request-bound result and exit status under a single deadline. See `Fixtures/LegacyProcessConsumer` for the child and parent setup.

A direct checked `Sendable` protocol can declare one ordinary `init(seed: Int)` requirement beside supported synchronous methods. Use the generated type's `makeConstructionScope(failureReporter:session:_:)` with a typed setup closure that receives the seed and instance stubs. Bind it with `withValue` around protocol-metatype construction. The session records the attempt before setup and records success after initialization. The new mock uses the same instance identity for its later calls. Detached tasks bind their own scope. [Independent constructor consumer](Fixtures/ConstructionConsumer/IndependentConsumer.swift)

The same construction scope supports one synchronous `init(seed: Int) throws(Failure)` requirement when `Failure` is a public same-module enum that directly conforms to `Error`. The setup closure throws that declared type. Failed attempts record a thrown phase and allocate no instance identity. Success records the new instance in the terminal event's `constructedMockID`. [Typed constructor consumer](Fixtures/TypedConstructionConsumer/IndependentConsumer.swift)

For one direct synchronous `init?(seed: Int)`, the setup closure returns `FailableConstructionDecision.initialize` or `.returnNil`. A configured nil completes the attempt with no instance link. The successful terminal records the initialized mock's ID. [Failable constructor consumer](Fixtures/TypedConstructionConsumer/FailableIndependentConsumer.swift)

For one direct nonthrowing `init(seed: Int) async`, the generated construction scope takes an async typed setup closure. The attempt stays active across suspension. During async setup the session records cancellation separately from completion. The generated witness attaches the initialized instance when setup returns. [Async constructor consumer](Fixtures/TypedConstructionConsumer/AsyncIndependentConsumer.swift)

The direct async constructor also supports `init(seed: Int) async throws(Failure)` with a public same-module error enum. During suspended setup the session records a cancellation request separately from the typed result. Setup can throw a declared failure or finish successfully. [Async typed constructor consumer](Fixtures/TypedConstructionConsumer/AsyncThrowingIndependentConsumer.swift)

A generated checked Sendable method can take one concrete noncopyable `consuming` argument and return `Int` in the supported synchronous profile. Provide `projectingInput:` as a typed borrowing closure when initializing the mock. Setup and verification use the projected `Int`; an answer receives the original input with its consuming convention. While the projection is pending, verification reports incomplete history. The runtime stores the projected metadata only.

A direct synchronous nonthrowing requirement can also return a concrete same-module noncopyable struct, with zero arguments or one `Int` argument. Configure it with `willProduce` and create a fresh result in the typed factory on each call. The caller owns the returned value and verification uses the ordinary arguments.

A supported direct `Sendable` protocol can use `func exchange(_ input: sending Packet) async -> sending Packet` for a public final class declared in the same module. The mock initializer takes `projectSendingInput` and `projectSendingResult`, each returning `Int` metadata. The typed async answer preserves `sending` in both directions. Verification reads the snapshots, including pending state during the transfer.

An explicit synchronous adapter can use `ByteBufferProjection().snapshot(buffer)` to record a byte count and base-address presence. To copy bytes during the buffer's valid lifetime, use `ByteBufferProjection(copyingPrefixAtMost: limit)` and pass the owned snapshot into your domain's mockable protocol. The snapshot includes the optional copied bytes and a truncation flag.

On Swift 6.4 and newer, a direct checked `Sendable` protocol can declare one synchronous `func read(_ source: borrowing Span<UInt8>) -> Int` requirement. Supply `projectingSpan:` when initializing the mock. The closure runs during the borrowed call and returns owned `[UInt8]` for typed matching, answers and history. Choose how many bytes to copy in that closure. Use a scoped adapter for other lifetime-bound shapes. [Scoped callback example](Fixtures/SpanConsumer/Sources/SpanDomain/ScopedSpanDirectory.swift)

An ordinary Sendable protocol mock can capture one final unary callback declared `@escaping @Sendable` on a synchronous, nonthrowing instance method. Matching and call history use the ordinary arguments. A winning stub can opt into retaining the callback with `EscapingCallbackCaptor`. Use the same `MockSession` for the mock and captor.

```swift
let session = MockSession()
let captor = EscapingCallbackCaptor<Int, String>(session: session)
let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
    stubs.register(id: .equal("row")).capturingCallback(into: captor).willReturn("registered")
}
_ = mock.register(id: "row") { value in "received \(value)" }
if let callback = captor.captures.first {
    let result = try callback.invoke(7)  // "received 7"
}
```

Delivery is synchronous and repeatable. Resetting or finishing the session releases stored closures and makes earlier handles throw `CallbackDeliveryError.unavailable`. A delivery that already acquired its closure can finish. This captor handles synchronous, nonthrowing callback types.

Use `OneShotEscapingCallbackCaptor` with `capturingCallbackOnce(into:)` for direct single delivery. Copies of one capture share the same claim. The first `invoke(_:)` obtains the closure. Another `invoke(_:)` or `cancel()` throws `.alreadyAcquired`, even while the first callback is still running. Cancelling a pending capture releases its closure and later attempts throw `.cancelled`. Finishing the capture's epoch produces `.finished`. Reset invalidates handles from the earlier epoch with `.unavailable`.

Call `let receipt = try oneShot.schedule(7, after: .seconds(3))` on a one-shot capture. Zero delay runs inline. A positive delay queues an attempt until a manual advance or a continuous timer acquires it at or after the deadline. Continuous attempts have independent timers. The first eligible attempt to acquire the shared capture wins. The receipt reports `.delivered(value)` for the winner and `.rejected(.alreadyAcquired)` when another attempt already claimed the capture. `receipt.cancel()` withdraws just that queued attempt. `oneShot.cancel()` retires the capture and competing attempts report `.rejected(.cancelled)` when due. Reset and session deallocation reject queued attempts as unavailable. Session finish rejects queued attempts as finished, and a callback that already acquired its closure can return.

On `MockSession(clock: .manual)`, use `let delivery = try callback.schedule(7, after: .seconds(3))` to schedule one delivery of a captured synchronous nonisolated callback. The receipt stays `.pending` until the delivery finishes or is retired. `advanceClock(by:)` acquires due callbacks and runs them outside the session lock before returning. At zero delay, `schedule` acquires and runs the callback immediately. Read `delivery.outcome` for `.delivered(value)`, `.cancelled`, or `.unavailable`. Call `delivery.cancel()` to remove its queued request. It returns `true` and records `.cancelled` only if that call removes the request. Once an advance acquires the callback, cancellation returns `false` even while its outcome is `.pending`. Reset and finish retire pending work. Callbacks already acquired by an advance can finish after teardown.

Single deliveries also work on a continuous session clock, the default for `MockSession()`. A zero delay still delivers inline. For a positive delay, a monotonic timer can acquire the callback at or after its deadline. Cancellation, reset, or finish can retire it while queued. An acquired callback runs outside the lock on the timer's task and can complete after teardown. Dropping a continuous session retires its queued deliveries.

For a finite series of the same callback and input, use `try callback.scheduleRepeating(7, after: [.seconds(1), .seconds(3)])`. The offsets share one registration time. `series.outcomes` reports each typed result in the supplied offset order. On a manual clock, an advance acquires all due occurrences, then runs them in deadline order. On a continuous clock, zero offsets run inline and positive offsets acquire and run one at a time in deadline order, with ties following the supplied order. `series.cancelPending()` removes queued occurrences and returns their count. Reset and finish also retire queued occurrences. Acquired occurrences can complete.

For a synchronous, nonthrowing `@MainActor` callback, use `MainActorEscapingCallbackCaptor` with the same stub syntax. Registration stays nonisolated. `invoke(_:)` runs on MainActor. Use `try await callback.invoke(value)` from another actor or a detached task. The actor-qualified name `@Swift.MainActor` can identify the standard actor explicitly in the protocol source.

For a synchronous callback declared `@escaping @MainActor @Sendable (Input) throws(DeclaredFailure) -> Output`, use `MainActorThrowingEscapingCallbackCaptor<Input, Output, DeclaredFailure>`. Replay with `try callback.invoke(input, onUnavailable: { .captureExpired })` on MainActor, or await the call from outside MainActor. Replay propagates the callback's declared failure. The supplied MainActor mapping provides your failure value only when the handle is unavailable.

For a nonisolated callback declared `@escaping @Sendable (Input) throws(DeclaredFailure) -> Output`, use `ThrowingEscapingCallbackCaptor<Input, Output, DeclaredFailure>`. The registration method stays nonthrowing. Replay with `try callback.invoke(input, onUnavailable: { .captureExpired })`, substituting a case of your own failure type. Replay propagates the callback's exact declared failure. The supplied mapping runs only when the handle has expired, such as after session reset or finish.

For a nonisolated callback declared `@escaping @Sendable (Input) async -> Output`, use `AsyncEscapingCallbackCaptor<Input, Output>` and replay with `try await callback.invoke(input)`. Registration stays synchronous. Replay runs in the caller's task and may suspend. Reset or finish clears stored callbacks and makes new replay attempts on old handles throw `CallbackDeliveryError.unavailable`. A replay that already acquired its callback can finish, even after session teardown. Replay does not count as an active mock call.

For `@escaping @MainActor @Sendable (Input) async -> Output`, use `MainActorAsyncEscapingCallbackCaptor<Input, Output>`. Registration still stays synchronous and can run off actor. Replay uses `try await callback.invoke(input)` and acquires the closure on MainActor. The callback runs on MainActor before and after suspension. Reset or finish rejects later acquisitions. An acquired replay can resume on MainActor after teardown.

For `@escaping @Sendable (Input) async throws(DeclaredFailure) -> Output`, use `AsyncThrowingEscapingCallbackCaptor<Input, Output, DeclaredFailure>` and `try await callback.invoke(input, onUnavailable: { .captureExpired })`. The `@Sendable` mapping supplies your failure value only for an expired handle. An acquired replay returns its value or throws its original declared failure even if reset or finish happens while it is suspended.

For `@escaping @MainActor @Sendable (Input) async throws(DeclaredFailure) -> Output`, use `MainActorAsyncThrowingEscapingCallbackCaptor<Input, Output, DeclaredFailure>` and `try await callback.invoke(input, onUnavailable: { .captureExpired })`. The callback runs on MainActor before and after suspension. An acquired replay retains its typed outcome across reset or finish. A stale attempt runs only the `@MainActor @Sendable` unavailability mapping on MainActor.

Set `maximumAsyncThrowingForwardingDepth:` to a positive integer when initializing a checked Sendable spy to bound recursive async-throwing call-through. Only active real forwarding hops count. A matching stub still wins at the limit. A blocked call reports once and follows the endpoint’s missing-call policy. A configured typed failure mapping turns the rejection into a declared error. Inherited tasks participate while their forwarding ancestry is active. Detached work starts with an independent path. This limit bounds opaque reentry through a real provider.

Checked async-throwing spies can declare a typed forwarding link. Configure an endpoint with `forwardingLinks: .init { $0.fetch(Int.self, through: link) }`, then bind the link with `link.bind(to: target.forwardingTargets.fetch(Int.self))`. The link binds once and holds its target weakly. A configured link takes precedence over `forwardingTo:` for that endpoint. Matching stubs keep first choice. If an endpoint would follow a link twice on the same path, the repeated call reports once and applies its missing-call policy. Each call keeps its own admission and outcome. A call from an opaque real provider starts a new structural path and can still participate in the configured depth limit.

The runtime supports typed equality, identity, optional, collection, string, numeric, custom and short-circuit logical matchers, last-registration-wins rules, immutable setup plans, return/answer stubs, typed async errors, admission/returned/threw count queries, and exact, minimum, maximum and inclusive-range counts. Use `.and`, `.or` and `.not()` to compose count predicates. An impossible combination produces a contradiction diagnostic. Use `Matcher.projecting(_:matching:)` to match typed enum payloads. Its extractor can reject a case before evaluating the payload matcher. Each endpoint has its own typed storage and append-only journal. No Any result casting, process-global registry, detached answer task, or unchecked Sendable conformance is used. User matchers, answers, and reporters execute outside journal synchronization.

Give a matcher an explicit diagnostic label with `Matcher<String>.satisfying { $0.hasPrefix("active-") }.named("active account")`. Runtime and generated verification failures include names from logical compositions. Multi-argument generated verification groups these names by the original argument labels and uses `_` for an unlabeled argument. The diagnostic shows `unnamed matcher` for an unnamed operand when at least one matcher has a name. Use fixed names that are safe to include in test output. Newly generated multi-argument verifiers use the runtime’s `matchingFields` helper. Pair the updated generator with a runtime that provides this helper.

Unstubbed nonthrowing Void calls report and return. An unstubbed value call reports before termination unless the endpoint has an explicit typed fallback. Methods declared `throws(Never)` retain that signature and can be called without `try`. An unstubbed ordinary throwing method reports the issue and throws `UnexpectedInvocationError`. Async typed-throwing endpoints optionally accept an explicit mapping to their declared failure type; catching that error does not suppress reporting. Configure generated mappings by endpoint, for example `failureMappings: .init { $0.fetchUser(id: String.self) { _ in .offline } }`. Index and argument metatypes identify overloads. Migrate numbered `failureMappingN:` arguments to the named configuration when regenerating. Typed verification reports an endpoint-local snapshot watermark and the caller's source location.

The runtime manifest declares macOS 13, iOS 16, tvOS 16, watchOS 9 and visionOS 1. The runtime uses Synchronization.Mutex where the OS supports it and NSLock on older Apple targets. The verification suite runs on Apple Swift 6.4 in Swift 6 language mode on arm64 macOS 27. Run `python3 scripts/verify_apple_deployment.py` with all five SDKs installed to link the runtime at the deployment floors, including both macOS architectures. The optional `--pre-mutex-ios-simulator DEVICE` check exercises the fallback lock and typed answers on an existing iOS 16 or 17 simulator. Execution on the exact older Apple releases still requires native testing.

Direct users of the checked Sendable `AsyncThrowingEndpoint` can publish a new configuration with `replaceConfiguration(_:)`. Each call keeps the plan and revision it received at admission through completion. The generated mock API still configures each mock during initialization.

Sendable async-throwing invocations run cooperatively in the caller’s task. While an answer is active, the session records a cancellation request in `snapshot().cancellationRequests`. The eventual return or declared error appears in `events` after the answer completes. Cancellation metadata has its own pruning boundary.

Sendable async-throwing stubs support `willSequence(.throwing(.offline), .returning(value), policy: .repeatLast)`. A sequence can also use typed `.answering` steps. The default finite policy reports exhaustion through the endpoint's configured failure behavior. Use `.repeatLast` or `.cycle` to continue after the final step. Each installed revision has its own cursor, and a step stays reserved if its answer throws or is cancelled. A history reset starts the new epoch at the position already reserved at reset time. Use `try session.resetHistoryAndSequences()` to rewind the installed sequences as part of the reset. Pass `.detachActive` to start the new epoch while old calls finish on their original cursors. The new epoch uses the same rule revision.

A checked synchronous typed-throwing selector also supports immediate `willSequence` steps. Use `.returning`, `.throwing` or a synchronous typed `.answering` closure. Finite exhaustion reports the issue and follows the selector's typed failure mapping. It retains the winning rule when exhausted. Reset inherits or rewinds the reserved position using the same policy as async sequences. [Independent synchronous sequence fixture](Fixtures/ProtocolConsumer/Tests/ConsumerTests/SyncThrowingSequenceTests.swift)

Use `.returning(value, after: .seconds(2), onCancellation: .offline)` to delay one typed async-throwing sequence step on the session clock. The delay starts when the reserved call registers its wait, after any winning-rule capture. A manual advance acquires an answer at its deadline and the invocation resumes on its own task. Cancellation that acquires the wait first throws the supplied error. The reserved step stays consumed, even when a detached history reset leaves the old call pending.

A checked async-throwing rule can use `willScenario(initial:transitions:onConflict:)`. Each transition specifies a state, a typed input matcher, the state to reserve, and an answer with the endpoint’s result and failure types. The last eligible transition reserves its state and answer together. When none is eligible, the invocation throws the configured conflict. An optional `onReturn` state applies only after a successful answer while the reservation's version and rule layer are still current. A newer transition, a detached reset, or scope exit leaves the original result intact and skips its state update.

A checked `SyncEndpoint` can opt into an explicit `DefaultValueRegistry`. Register factories for the exact result type with `.registering(Type.self) { context in ... }`, then pass the registry as `defaultValues:`. The endpoint consults it after stub matching and forwarding. A factory may obtain another declared type with `try context.require(OtherType.self)`. Missing factories, recursive type cycles and excessive depth return a typed registry error. An unstubbed nonthrowing endpoint reports that error and terminates the invocation.

Use `DefaultValueRegistry.safePrimitives()` to opt into `false` for `Bool`, `0` for `Int`, and an empty `String`. `.registeringNil(MyType?.self)` registers `nil` for that exact optional. `.registeringEmpty([MyType].self)`, `.registeringEmpty([Key: MyType].self)` and `.registeringEmpty(Set<MyType>.self)` register exact empty collection recipes. You can override a recipe with a typed factory.

Pass the same `MockSession` to multiple generated Sendable mocks to inspect a shared, ordered timeline with `session.snapshot()`. Each mock keeps its own typed history and has its own identity. A generated Sendable mock creates a private session when none is supplied.

Use `try session.resetHistory()` to clear history once all calls have completed, or `try session.resetHistory(.detachActive)` to start a fresh epoch while old calls finish. Detachment keeps the old epoch's event metadata. Typed arguments are discarded from endpoint history, and old calls do not update the new epoch's counts. Reset keeps configured rules and stored property values. Build a new verification descriptor after reset. An old descriptor fails as stale and does not evaluate its matcher.

Use `ProjectedSyncEndpoint` or `ProjectedAsyncThrowingEndpoint` with an `InvocationProjection(argument:result:)` to retain selected Sendable fields. A thrown call records an unavailable result. A returned optional nil remains a valid input to the result projection. Supply value snapshots such as identifiers or redacted summaries when history must survive changes to an object. `projectedHistory()` returns the endpoint's current-epoch records. A field stays pending while its projection runs, and a result publishes together with its returned phase. Verify a projected history with `verify(_:matchingArgument:phase:)` or `verify(_:matchingResult:phase:)`. Complete successful assertions return typed captures in admission order. Pending or unavailable fields are reported when they prevent a complete capture. Use `WeakProjectedReference` when you need to inspect an object's identity while it is alive. Its live `object` read can return nil after deallocation, while the capture keeps its invocation metadata.

Use `session.checkpoint()` and `try session.events(since: checkpoint)` to read the events added after a position. This includes completions of calls admitted before the checkpoint. A foreign session or a reset epoch produces a typed error.

Use `session.withContext { ... }` to bind an epoch to the current lexical scope. Structured child tasks inherit the token. Detached work and callbacks can capture `session.contextHandle` and rebind it explicitly with `session.withContext(handle) { ... }`. Validation rejects missing, foreign and stale context. Keep passing `session:` explicitly when constructing instance mocks.

Call `session.snapshot().matchOrder(_:mode:phase:)` to read cross-mock order by mock and endpoint IDs. Relative mode allows intervening events. Strict mode requires consecutive matches in the selected phase. A selector from a different session is rejected. Use `session.snapshot().matchCompletion(of:beforeStartOf:phase:)` to find a completed invocation followed by a distinct invocation's admission in the same epoch.

Await `session.waitForQuiescence(until: deadline, clock: clock)` to observe a snapshot with no active calls, including calls in detached epochs. Waiting is cancellable, and the deadline is exclusive. Producers can admit new calls after the snapshot.

Use `try await endpoint.withScopedConfiguration(plan) { ... }` to layer rules on a checked `AsyncThrowingEndpoint` for one lexical operation. Calls use the innermost matching layer. A miss consults outer layers, then the base and forwarding. An exhausted winning sequence reports exhaustion and follows the endpoint's failure mapping. Scope exit restores the previous layer after a return, throw or cancellation. Calls retain the layers they received at admission, including during a detached reset. An inherited scope token from a closed or reset scope rejects new calls. Detached tasks begin without inherited layers. Use `stub.priority(_:)` on a checked async-throwing rule to rank it within its own configuration. Higher priority wins. Equal priorities favor the latest registration. Scope precedence applies before priority. To configure scopes on a generated mock, opt a supported direct Sendable async-throwing method in with `--scoped-rule 'fetch(id:)'` and call `mock.ruleScopes.fetch(id: String.self, configure: ..., operation: ...)`. The metatype selects the declaration. The configuration uses the normal typed matcher and answer APIs, and the operation retains caller isolation.

A direct checked endpoint can export its active chain with `try endpoint.currentScopedConfiguration()`. Pass the handle to a detached task and bind it with `try await endpoint.withScopedConfiguration(handle) { ... }` while the originating lexical scopes are active. The handle is specific to that endpoint and session. Scope exit, reset or finish invalidates future bindings. The handle retains metadata and leaves other endpoints' bindings in place.

Use `try endpoint.replaceConfigurationIfQuiescent(plan)` on a direct `AsyncThrowingEndpoint` when replacing its stubs requires an idle session. The idle check and publication are atomic. The check includes active calls from earlier epochs. It throws `QuiescentConfigurationError` for active calls, a finished session, or a stale epoch-bound scope.

Use `try await endpoint.replaceConfigurationWhenQuiescent(plan, within: .seconds(2))` to let existing calls finish. It publishes before the next admission at an eligible idle boundary. The deadline uses the session clock and is exclusive. A timeout or cancellation before publication leaves the current plan intact. Request the update outside calls the update needs to drain.

After your tasks have finished, call `try session.finishIfQuiescent()` to close admission and preserve the final timeline. Active calls cause a typed error. A later mock call reports through its original endpoint reporter and uses the endpoint's legal fallback, error mapping or termination behavior. It leaves final history unchanged. This operation does not join application tasks.

Share an `OrphanFailureBuffer` with `MockSession(orphanFailures: buffer)` to collect rejected calls from closed sessions. In an active Swift Testing run, import `BlueprintMockingTesting` and call `await FailureReporter.flushSwiftTestingOrphans(buffer)`. The flush reports the batch at run level and includes original session and source information. Join known producers before the final flush. Custom harnesses can claim a batch with `buffer.drain()` and use its dropped count when determining the run result.

On macOS XCTest, import `BlueprintMockingXCTest` and call `try FailureReporter.flushXCTestOrphans(buffer, in: suiteRun)` on the runner’s path for an active suite. Pass the suite run explicitly, for example from an `XCTestObservation` hook. The flush records issues at suite level. An inactive suite throws before it claims the buffer.

On macOS XCTest, an explicit case owner can record a collected `MockIssue` with `try FailureReporter.recordXCTestIssue(issue, in: testCase)` on the active case's runner path. XCTest receives the original file and line, including paths supplied as dynamic strings. Callers supply the owning case and record the issue before that case finishes.

Use `try session.discardEvents(through: checkpoint)` to discard a current epoch's session metadata prefix. A checkpoint that misses a discarded event reports unavailable history. A gap in global ordinals alone is valid because another epoch can receive events. Endpoint argument histories are separate.

Use `try session.verifyNoInteractions(in: .session)` to check for admissions through the current snapshot, or pass `.mock(mockID)` to check one mock. Use `since:` to start after a checkpoint and `ignoring:` to exclude explicit mock-and-endpoint pairs. A retained admission disproves absence. A pruned prefix can leave the result unavailable.

Create an epoch-scoped verification scope with `session.consumptionScope(named:)`. Use `try session.consume(.earliest(1), for: selector, in: scope)` to claim one matching admission, or `.all` to claim every match in the snapshot. A concurrent change to the same scope can cause a conflict. A failed claim leaves the scope unchanged. Use `try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope)` to check for unclaimed admissions. Ordinary interaction and typed count checks still include claimed calls. Projected endpoints also accept `consume(_:matchingArgument:phase:in:)`. The resulting bundle contains the claimed IDs and the typed records selected from the same snapshot. Pending projections can prevent a claim.

Use `try session.consumeInOrder([first, second], mode: .relative, in: scope)` to claim the earliest matching sequence together. Pass `.strict` to require consecutive events in the selected phase. Calls already claimed in that scope still occupy their position in strict order. A missing sequence returns `nil` without claiming anything. Pruned history prevents an earliest-sequence claim.

For live observation, retain `session.observeChanges()`, then use its notifications as wake-ups. Read `try session.replay(since: checkpoint)` after a wake and use the returned checkpoint for the next read. Replay returns all retained events through that position, so coalesced wakes preserve intermediate transitions. Cancel the observation when finished.

Use `session.eventually(_:for:phase:within:)` to find the first committed metadata count that satisfies the predicate before a session-clock deadline. A late wake still sees a qualifying pre-deadline prefix, even if a later call invalidates it. Use the `until:clock:` overload to supply a Swift clock and bound when the observer must see a qualifying prefix. Both overloads throw when unavailability of history prevents evaluating the query.

Use `session.until(_:for:phase:for:)` to require a count to hold throughout an interval, or `session.stable(_:for:phase:for:within:)` to wait for an uninterrupted satisfying window. Both count committed events by mock, endpoint, and phase. Events stamped at the interval's ending boundary are outside that interval. Time defaults to a monotonic clock. Use `MockSession(clock: .manual)` and `try session.advanceClock(by:)` for deterministic tests. Projected Sendable endpoints with String argument snapshots also support `stable(_:matchingArgument:for:within:)`. A pending admission interrupts the candidate, and publication can start a fresh window. The assertion reports incomplete history when unsettled data prevents the proof at the deadline. The `matchingResult` overload counts literal String result snapshots. An in-flight result stays pending until terminal publication. A typed throw settles as a known non-return.

For the Ubuntu 24.04 arm64 runtime profile, run `bash scripts/verify_linux_runtime.sh --help` to prefetch the pinned Swift image, then `bash scripts/verify_linux_runtime.sh` to test a committed revision with networking disabled. The workflow exercises the runtime, archived generated mocks, both reporters, and runtime-only linkage. Linux code generation, Ubuntu 22.04, Linux x86_64 and Windows still require verification.

The MainActor mock keeps setup, matchers, answers, invocation history, and verification on MainActor. A matcher can observe actor-local state, and an answer may return an actor-local reference. History retains those references and evaluates matchers against their state at verification time. The sample includes a consumer workflow and checks that illegal cross-actor access fails compilation. Custom global actors, Actor-constrained protocols, projections, advanced history and sessions, additional declaration families, plugins, migration and release certification remain roadmap work.

See the [implementation evidence](Docs/Implementation-Evidence.md) for the verified scope and the next slice. The [contribution guide](CONTRIBUTING.md) explains the TDD workflow and how to submit a milestone.

This repository is licensed under the [MIT License](LICENSE).
