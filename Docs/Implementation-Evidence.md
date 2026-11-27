# Protocol mocking implementation evidence

The target is Blueprint Mocking Full Product Architecture edition 1.0 (6 October 2026), especially A2.2, A3.1, R1.1–R1.2, R2.1, R4.1, and R5.1–R5.2. The public roadmap retains all 125 acceptance contracts. The architecture's Mockingbird comparison is a historical design benchmark, not a current compatibility or superiority claim.

## Changes

| Location | Implemented behavior |
| --- | --- |
| Package.swift | Runtime-only dependency graph; optional Swift Testing reporting product |
| Sources/BlueprintMocking/Runtime.swift | Typed sync and async-throwing endpoints, immutable setup, checked Sendable journals, matchers, count verification, neutral issues |
| Sources/BlueprintMockingTesting/Reporter.swift | Swift Testing issue reporting using the verification caller's source location |
| Packages/Tooling/Sources/BlueprintMockingCLI/main.swift | SwiftParser frontend, restricted validated declarations, sorted endpoint identities, witness/setup/verification emission |
| scripts/generate.sh | Explicit SDK/target host compilation using toolchain-bundled parser libraries |
| Fixtures/ProtocolConsumer | Separate production module, generated doubles, executable service example, overload/typed-error/MainActor-consumer tests |
| Fixtures/RuntimeOnly | Runtime consumer with no generator or runner product dependency |
| Tests/BlueprintMockingTests | Runtime behavior, prefix verification, mapping, concurrency, reentrancy, and suspended-call identity |
| Fixtures/CompileFailures and GeneratorRejections | Wrong types/effects/captures/schema; unsupported syntax/profile diagnostics |
| scripts/verify.py | End-to-end entry point, expected-failure subprocesses, source/linkage/dependency checks |
| Docs/Acceptance-Status.csv | Roadmap with original acceptance IDs, evidence and remaining work |

## Evidence

The initial tests failed to compile against the empty runtime and passed after the typed endpoints were implemented.

Run `python3 scripts/verify.py` to reproduce the checks. It writes `Evidence/results.json`, `Evidence/profile.json`, and build and test logs in your local checkout.

The baseline runtime suite had 10 tests. It proves setup/verification do not invoke endpoints; return/throw/answer preserve their types; diagnostic labels do not share storage; precedence is explicit; verification keeps a frozen prefix and source location; caught mapped errors still report; matchers/answers/reporters can reenter; 8 tasks make 1,000 uniquely recorded calls; and two suspended calls can finish in reverse order without changing admission identity.

The baseline consumer suite had 5 tests, including the ordinary disabled branch of the intentional-failure harness. Four exercise successful workflows: service injection, generated typed errors, a MainActor consumer, and independent overloaded endpoints. The harness is separately activated and filtered to prove that a verification mismatch fails Swift Testing at ConsumerTests.swift's assertion line.

Seven compiler fixtures must fail for the intended reason: wrong result, wrong typed error, wrong generated typed error, async answer for a sync method, non-Sendable capture, missing schema marker, and throw configuration on a sync nonthrowing endpoint. Four generator fixtures must fail with BPM001 while preserving an existing output: malformed source, property requirements, actor profile, and untyped throws.

Repeated generation and a relocated source with token whitespace changes must produce the same bytes. This limited check is not full cross-platform reproducibility certification. Source line provenance means adding/reordering lines can legitimately change output; broader stable-identity fixtures remain required.

The executable demo is also run through `swift run`. Unstubbed typed-throwing and synchronous value calls run in separate child processes: each must emit an issue before terminating. The runtime-only consumer runs independently; otool and the package dependency graph check that no parser/test-runner library is required by that executable. No network-blocked offline certification was performed.

## Limits and next slice

Every mapped contract remains partial; all other contracts remain visible as unimplemented. This is one local compiler/SDK/OS profile, with no release certification or performance claim. The package declares older Apple deployment floors and links the runtime for each floor with Apple SDK 27. Execution evidence is from the current macOS host. Native tests on the deployment floors, a platform matrix and a packaged SwiftSyntax dependency remain outstanding.

The second milestone adds a generated MainActor mock for GEN-035 and RUN-020. It uses actor-local storage for non-Sendable inputs and outputs, and preserves the actor boundary in setup, matchers, sync and typed async answers, and verification. A suspended async answer keeps its invocation identity, and a reentrant matcher sees the same verification prefix throughout the assertion. The runtime suite has 13 tests and the external consumer has 6. The compiler fixtures reject cross-isolation witness, setup, descriptor, and assertion access. Explicit nonisolated callers still fail with MainActor default isolation enabled. The SIL fixture rejects returning a non-Sendable reference across the actor boundary. Custom global actors and Actor-constrained conformers remain to be implemented.

Introduce session-coordinated identities and lifecycle invariants before implementing live revisions/reset or cross-mock ordering (SYS-007, RUN-014, RUN-034, RUN-036, RUN-042). The original matrix remains the completion definition.

## Explicit dependency adapters

SYS-005 exercises a final class, a struct, and a free function through three injected protocols in the independent SwiftPM consumer. `CheckoutQuoteService` uses the live wrappers in one test and typed generated doubles in the other. The mock path verifies each argument and returned call. Calling the original dependencies directly with the same arguments leaves the complete session snapshot and counts unchanged. The verifier regenerates all three checked-in witnesses and compares the bytes.

These fixtures cover the functional SYS-005 gate on the tested arm64 macOS toolchain. The release profile runs and review remain open. [Dependency adapters](../README.md#testing-final-classes-value-types-and-free-functions)

## Timed session assertions

RUN-031, RUN-032 and RUN-033 have local evidence for sustained metadata counts. The session assigns elapsed time and ordinal in the same event transaction. The observer replays retained events in order and returns the last included watermark at an exclusive deadline. Manual-clock fixtures cover a brief violation between wakes, a restarted window, equal-time events, cancellation, early finish, reset, and unavailable history. The generated-mock consumer exercises the public API using a specific endpoint and completion phase. The current timed API supports session-owned manual and continuous clocks. Richer timeout diagnostics, immutable argument and result projections, and certification across supported profiles remain open.

## Projection and certification evidence

Sendable synchronous and async-throwing endpoints can retain typed argument and result projections. Public SwiftPM consumers verify pending publication, immutable copies after raw mutation, weak references after deallocation, thrown and optional results, and detached completion across reset. Immediate verification returns captures only for a complete successful assertion. Consuming verification publishes a typed capture bundle when the scope claim commits. The standalone generator now supports explicit projection selectors for Sendable synchronous nonthrowing and async-throwing methods. Its external SwiftPM consumer calls the projected mock through the protocol and exercises typed history, mutation, pending data and detached reset. Sendable synchronous and async-throwing stubs support winning-rule captures through generated and direct endpoints. Async captures follow successful reservation and preserve the admitted configuration revision across replacement. Consumer fixtures cover competing and negated rules, reentrant matchers and captors, concurrent admission, reset, stale publication, and release outside locks. String argument stability for direct projected Sendable endpoints uses admission and publication timestamps to distinguish pending and settled intervals. String result stability uses the terminal event's timestamp and treats a typed throw as a settled non-return. The generated verification surface also exposes String argument and result stability. The external fixture proves an argument window, rejects a pending result as incomplete, and proves the fresh result after reset. Other effect and isolation profiles and richer temporal predicates remain open.

For RUN-006, `xcrun swift test --filter 'RUN006'` exercises equality versus identity, optional matching, and typed case extraction in both Sendable and MainActor fixtures. The pre-Mutex iOS probe in `scripts/verify_apple_deployment.py` also exercises equality, identity, and typed case projection on the available iOS 17.5 simulator. These runs provide scoped evidence. Native execution on the remaining applicable Apple, Ubuntu, and Windows profiles and review of the exact applicable profile plan remain required.

For RUN-007, named predicates and logical compositions carry explicit diagnostic labels through Sendable and MainActor verification. The runtime tests confirm that reading the description does not evaluate the predicate, that the existing unlabeled count message is preserved, and that matchers do not render the input or expected value. Independent generated consumer tests verify single-argument diagnostics and Sendable and MainActor multi-argument diagnostics. The multi-argument tests compare the complete messages for source labels, unnamed fields, redaction of actual and expected values, and unchanged output when no fields are named. The winning-rule capture test covers negation, overlap and rejected matches with reentrant and concurrent calls. Applicable release profile certification remains open.

For SYS-008, the canonical verifier runs `test_check_release.py` and `test_verify_release_candidate.py` as separate named checks. The first rejects a missing source reference, check name, or required profile result. The second exercises the signed-candidate boundary with disposable repositories and keys. Both suites use fixture metadata for the claims they test.

The focused command `python3 scripts/verify.py --release-checks-only` runs those same suites without Swift builds. It writes `release-checks.json` after both suites execute successfully and the checkout is clean at the same revision before and after the run. Each result records the exit status and log hash. A failed or empty suite removes any prior scoped report. Certification requires reviewer approval of the applicable evaluator profiles and evidence from each profile at the selected revision.

The release checker requires every profile artifact for a completed contract to bind to the same full candidate revision and to that artifact’s declared profile. A two-profile fixture certifies its synthetic contract with distinct matching results. Stale or substituted results and duplicate profile tuples fail. The [candidate release profile plan](Release-Profile-Plan.md) lists the proposed SYS-008 evaluator, the remaining native runs, and evidence requirements for review.

## Generated runtime compatibility

GEN-007 now checks the runtime marker from the imported `BlueprintMocking` module. A native compiler fixture generates an async-throwing instance witness and a static-subscript witness. It compiles the same emitted source and consumer-local lookalike against two separately built runtime modules. The actual marker compiles. Renaming only the runtime’s marker produces a compiler error at both generated compatibility fields. The static accessor fallbacks also reference the runtime module.

The independent SwiftPM consumer proves that typed async-throwing setup and synchronous count verification leave the session snapshot and answer count unchanged. Calling the witness then produces one answer and one admission/return pair. These checks cover GEN007-A and GEN007-B for the tested generator profile. The configured Swift index serves as the compact manifest. Its typed IR and runtime-contract versions share the generator’s constants for endpoint identities and the public marker. A standalone consumer compiles and reads both versions from an empty generated pair. Editing the runtime version is detected as index-only drift, and an independent generation reproduces the original pair. Class generation, dynamic descriptor compatibility and release-profile qualification remain open.

## Sequence cursors across epoch resets

RUN-034 now keeps installed async-throwing rule cursors local to each epoch. A reset takes the same session lock as sequence reservation and copies the reserved position into the new epoch without changing the rule revision. An invocation admitted before reset still uses the old cursor. Matchers and answers run outside the session lock.

An independent generated `UserRepository` consumer holds an admitted call inside its matcher before it can reserve. The tests verify that a quiescent reset refuses the active call, then exercise both preserving and restarting the cursor in a detached reset. The archived completion pairs with its original admission while current counts and reservations stay independent. A quiescent restart rewinds exhausted finite rules and advanced cycling rules in the same revision. The existing reset transaction retires queued callback work. Independent rule and callback-work reset policies need defined behavior, and release-profile qualification remains open.

## Public SwiftPM installation

`python3 scripts/verify_remote_install.py <commit>` runs committed fixtures in fresh scratch using the public GitHub URL and a fresh SwiftPM cache shared within that run. It builds and runs the runtime-only product and runs actual Swift Testing and XCTest test targets. Each lockfile must record the repository identity and exact commit. All three fixtures passed at `8937eb9`, `568502a`, and `44ba673` on the tested macOS toolchain. The runtime package's product name is `BluepringMockingFramework` and its module is `BlueprintMocking`.

The optional `--version <exact-semver>` makes those fixtures resolve the supplied exact version and checks the resulting commit. Manifest and pin validation for exact versions are covered by unit tests. Live SemVer verification requires an approved release tag at the candidate commit.

## Parameterized reporter ownership

For each available mode, the local verifier runs two concurrent cases of one Swift Testing function in an isolated failure subprocess. Both cases have the same native function ID and distinct mock sessions. The peer holds its scope open while a detached task explicitly rebinds the owner's type scope. The fixture's neutral reporter captures the detached issue, and the live owner delivers it through the normal Swift Testing adapter. The verifier checks the native runner's owner argument, the generated source location, the single issue count and zero issues at the peer.

A scratch control delivered the same issue from the peer and still produced one native failure under the same function ID. The attribution check rejected the peer argument.

The explicit fixture uses the Swift 6.0 scoped path. The optional per-case fixture uses the [Swift Testing test scoping trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0007-test-scoping-traits.md) when the compiler supports it. Both modes use the package's existing test dependencies.

## Finished Swift Testing case ownership

The native fixture runs two parameter cases of one Swift Testing function with distinct mock sessions. The verifier waits for A's native `testCaseEnded` event and B's readiness before releasing a callback that uses A's finished session. It repeats the run with an inherited task, a detached task, and a Foundation thread. The session snapshots stay fixed, and only A's neutral reporter receives an issue.

The normal Swift Testing adapter attributed the captured issue to B when drained from B in a test-first control. In a separate probe, direct recording from A's inherited task retained A's completed case ID. The new adapter method `reportAtSwiftTestingRunLevel(_:)` detaches delivery and records the native event at the adapter's location. Its diagnostic includes the original generated source.

On Apple Swift 6.4 with Swift Testing 2084, the verifier requires one failing native issue without a test or case ID, between A's end and B's end. It checks that the native run finishes and SwiftPM exits 1. The fixture uses Swift 6.0 language features. The native case-boundary check is enabled by the verifier on Swift 6.4 or newer. Native Swift 6.0 and other runner profiles, XCTest run-level delivery, and automatic run-scoped buffering and deduplication remain outstanding. DX-023 and RUN-038 remain partial.

## Quiescent configuration replacement

RUN-035 adds the direct `AsyncThrowingEndpoint.replaceConfigurationIfQuiescent(_:)` operation. It checks all session epochs and publishes the new revision under the same lock used for admission. Active calls, finished sessions, and stale epoch-bound scopes produce typed errors. A refusal preserves the plan and its revision.

Deterministic runtime fixtures hold a sibling invocation across an epoch reset, check stale and finished scope rejection, and race two successful replacement candidates. An external SwiftPM executable proves that a retired plan's destructor can read both histories and perform a nested replacement. The verifier bounds the executable's runtime so a lock regression fails the check. The Apple SDK cross-links the runtime at all six declared target triples. The iOS 17.5 simulator also executes a successful replacement through the NSLock fallback using the iOS 16 build target. Deadline-based replacement, managed teardown and native certification remain outstanding.

## Bounded fatal-child verification

DX-029's six fatal consumer paths run in separate processes. For each path, the verifier requires the expected termination signal and one endpoint-specific issue on stderr before one fatal diagnostic. It captures up to 4 KiB of stderr, enforces a 10-second deadline through process exit, and reaps timed-out or oversized processes. The local arm64 macOS paths all terminated with `SIGTRAP`.

Synthetic children exercise ordinary failure with valid-looking diagnostics, an unexpected signal, reordered or duplicate diagnostics, stdout-only diagnostics, a buffer exactly at the limit, overflow, and a hang after stderr closes. The x86_64 verifier expects `SIGILL`, pending native validation. Additional native runner profiles and the full legal-fallback matrix remain outstanding.

## Automatic orphan buffering

A test runner or custom harness can share an `OrphanFailureBuffer` through explicitly enrolled sessions. A rejected call from a closed session queues directly, retaining the session, original epoch, mock and issue. Concurrent drains atomically claim disjoint batches. Separate failures get separate ordinals even when their diagnostics match.

The buffer caps both pending records and retained bytes per issue. A drain atomically takes the drop count with its records, and Swift Testing fails the run even when a batch contains only drops. A generated post-close getter with no legal fallback emits a synchronous, runner-neutral diagnostic before it traps. A process-level durable transport remains outstanding.

The native Swift Testing fixture uses the product buffer for inherited, detached and Foundation-thread callbacks after native A-end while B stays active. The host verifier checks exactly one run-level issue and a failed process. This evidence uses Apple Swift 6.4 and Swift Testing 2084. Pending delivery while a foreign call still has an open owner and framework-managed finish remain open.

## XCTest suite-level orphan delivery

On macOS, `FailureReporter.flushXCTestOrphans(_:in:)` claims the neutral buffer and records its issues on an explicitly selected active `XCTestSuiteRun`. Native issues retain their original file and line. The detailed description carries owner metadata and the original column. An inactive suite rejects the flush before claiming any records. Drops produce an additional failing suite issue.

The native SwiftPM fixture waits for A’s `testCaseDidFinish` observation, releases A’s callback from B, and verifies both case runs finish with zero failures. The suite records the orphan and SwiftPM exits 1. A deliberate control replays the same captured issue through the ambient adapter while B is active. The control records a B case failure and no suite-owned issue. A separate enabled fixture verifies overflow and a repeated flush.

The checked profile is Apple Swift 6.4 on arm64 macOS 27.0.1. Exercising an active suite on other native XCTest profiles and a portable transport after the runner exits remains outstanding.

## Deadline-based quiescent replacement

`AsyncThrowingEndpoint.replaceConfigurationWhenQuiescent(_:within:)` prepares the replacement before entering the session gate. A registered plan publishes at a zero-active boundary before the next admission. The exclusive deadline is checked under the session and endpoint locks, and uses the session’s continuous or manual clock.

The tests cover expiry exactly at the deadline, cancellation before publication, publication that wins a cancellation race, FIFO waiting, and reset with an active call in a detached epoch. The external SwiftPM demo uses the public API. The iOS 17.5 smoke probe exercises it through the NSLock fallback.

Managed teardown and detection of a replacement awaited by its own active invocation remain open. Callers must request a replacement outside the work it awaits. Full native certification remains outstanding.

## Source-built SwiftPM build plugin

DX-004 now has local evidence from an independent consumer. The root package supplies the runtime. The separate `Packages/Tooling` package supplies `blueprint-mocking` and `BlueprintMockingBuildPlugin` and pins SwiftSyntax 600.0.1. The standalone script and the package executable compile the same generator source.

The plugin derives input membership from direct Swift targets in the consumer package. It declares the configuration and source files as build inputs and uses one ordinary build command. The command emits one Swift shard and a stable index in SwiftPM’s plugin work directory. Input membership is sorted and included in the command. Unrelated source membership changes update the index without rewriting the mock shard. The index references the shard’s content marker.

The clean fixture compiles and runs a typed generated mock, proves an unchanged repeat skips generation, and checks addition, deletion, edits and renames. Unsupported syntax and a missing selected protocol stop the build before any output changes. The runtime-only consumer still resolves a single package with no transitive dependencies and links without parser or runner libraries.

The checked profile is Apple Swift 6.4 on arm64 macOS. Separately hosted tooling distribution, complete compiler context, configurable sharding, prepared offline and other native profiles remain open.

## SwiftSyntax resolution in a consumer package

The SwiftPM plugin pulls the tooling package into the consumer's dependency graph. `scripts/verify_swiftpm_compatibility.py` runs isolated, file-only SwiftPM resolution using the checked-in runtime, tooling and consumer manifests. The disposable SwiftSyntax mirror supplies version and product metadata for `600.0.1` and `601.0.0`. A runtime-only consumer can resolve its own exact `601.0.0` pin. A consumer using the source-built plugin resolves with `600.0.1`, and SwiftPM reports conflicting requirements when that consumer pins `601.0.0`.

Run the solver fixture with `python3 scripts/verify_swiftpm_compatibility.py --evidence-dir "$artifact_dir/compatibility"`. The report records the manifests, resolved graphs, lockfiles, and rejection log by SHA-256. The run resolves packages without compiling parser or plugin targets.

Consumers with a different SwiftSyntax pin can run the standalone generator from the authoring checkout and add the emitted Swift to their test target. The standalone script uses the selected Xcode toolchain’s bundled parser.

The prepared-host parser-parity harness compares three successful requests covering typed lookup, diamond inheritance and dependent associated types. It also compares the missing-parent and conflicting-element rejections. It runs both generators on the same staged committed inputs under a verified macOS network block. The harness compares the full shard and index bytes and the exact exit and diagnostic bytes. Raw logs retain loader traces. Diagnostic comparison filters the recognized loader records and removes the known staged directory prefix from generator text. Rejections must preserve the previously generated pair.

The verifier checks receipts from each trusted build producer. It rejects the same executable by identity or digest, checks the selected Xcode dylibs in the bundled loader trace, and checks the packaged route's exact SwiftSyntax 600.0.1 lockfile, checkout bytes, native link inputs and defined parser symbols. The packaged loader trace must show no dynamic parser images. A passing report is created only after every request agrees. Unit tests deliberately change output and diagnostic bytes and require the verifier to clear prior passing evidence. The actual CLI rejects an attempted self-comparison.

The prepared Xcode generator passed its five individual requests on arm64 macOS. Real two-parser parity still needs the compiled SwiftSyntax 600.0.1 executable from the same authoring revision. See the prepared-host command in the README. Exported tooling compilation, hosted distribution, signed build provenance and native-profile qualification retain their own gates.

## Reproducible local tooling source exports

The checked-in `Packages/Tooling/ExportManifest.json` specifies the standalone payload and compatibility. The exporter flattens the tooling package to the archive root, adds the repository’s MIT license, and records the authoring revision, the SwiftSyntax pin, and the SHA-256 of each shipped file. Sorted regular-file entries and fixed tar metadata make the archive repeatable. Verification rebuilds the expected archive from raw Git blobs before extraction.

Tests cover repeatable exports across checkout paths, staged and unstaged source changes, archive attributes, corrupted bytes, unsafe paths, a tracked symlink, and an internally consistent older archive checked against a newer revision. The local install verifier places the exact unpacked artifact in a disposable Git repository and checks the consumer’s tooling, runtime and SwiftSyntax pins. The installed SwiftPM checkout matches each verified archive file by SHA-256 and exposes the expected executable and plugin products. A separate runtime-only fixture resolves zero transitive dependencies.

The same installer rejects a source archive with altered Swift bytes and a refreshed embedded file hash. It also rejects an internally valid earlier archive supplied at the current revision. The test traps any attempt to start the Swift toolchain, checks that the complete prior evidence directory remains unchanged, and records both actual CLI exits. The archive preflight runs before creating the extraction workspace or invoking SwiftPM.

This milestone covers local source packaging and resolution through a prepared local mirror on Apple Swift 6.4. The checks use file-only Git transport. Compilation from the exported tooling package, offline generation, hosted tooling distribution and signed release exports remain open.

## Offline runtime installation from a prepared mirror

DX-001 and SYS-003 have native evidence for a clean SwiftPM runtime consumer at an exact revision. The verifier stages the consumer from committed files, preserves its public package URL and points SwiftPM at a prepared bare mirror in isolated configuration. It checks the lockfile, the independent SwiftPM checkout and the graph with zero transitive runtime dependencies. Git replacement refs are disabled so fixture reads honor the committed objects.

Before resolving, the verifier connects to a local test listener and then requires a child-reported permission error under the same macOS policy used to resolve, build and run. The executable's Mach-O load commands identify macOS 13.0 as the deployment target. Dynamic library inspection excludes parser, generator and reporter libraries, and the native SwiftPM link-input file lists only the compiled core and consumer objects. The verifier selects the native build system to inspect these original link inputs. The runtime smoke fixture configures a typed stub, invokes it and verifies the call.

The local evidence uses Apple Swift 6.4 on arm64 macOS. The report records the selected compiler, SDK, host build, Git revision, network probe, executable hash and evidence digests. The main verifier captures the report's SHA-256. Additional native profiles and maintainer review remain. The wider DX-020 contract still requires full offline generator qualification, the remaining artifact-class corruption cases and trusted release provenance. The SwiftSyntax cache contains the pinned 600.0.1 source mirror. Packaged parser compilation and parity require a prepared compiled cache or a separate build host.

## Git mirror integrity before SwiftPM consumption

The offline runtime installer checks the prepared Git object store before choosing a Swift toolchain, probing the network, or changing evidence. Full strict Git verification checks object integrity and connectivity. Replacement refs and lazy fetches are disabled for the file-only lane. A valid mirror still resolves, builds and runs offline as described above. [Git object verification](https://git-scm.com/docs/git-fsck)

The DX-020 corruption fixture copies the pinned commit graph into a disposable bare mirror and changes a readable `Package.swift` blob under its original object path. The commit and manifest object IDs seen from the commit remain unchanged. Before the integrity check, the real installer accepted this mirror and built the consumer. It now rejects the same mutation at the Git check and leaves the prior valid consumer report unchanged. The named `reject-runtime-mirror-corruption` result binds the rejection log and original and altered manifest digests to the exact input revision.

This verifies a prepared local Git mirror against the expected commit. Publisher authentication, other artifact classes and cross-host qualification retain their own gates.

## Configured generation with network denial

The DX-020 verifier stages an independent SwiftPM package from the exact commit. A loopback connection succeeds in the control and the same probe reports a permission error under the macOS network policy. The configured generator starts with an absent output directory for each run. The normal and network-blocked runs use the same request and emit byte-identical shard and index files. The index references the shard marker and the fixed input-set ID.

Both runs capture the actual loader paths of the selected Xcode toolchain's host SwiftParser and SwiftSyntax dylibs. The verifier records their hashes and the generator hash. It checks the generated pair, resolves the exact runtime dependency from the prepared Git mirror, and builds and runs the staged SwiftPM consumer under the same network denial. The Swift consumer references the index alias, calls the typed mock through the authored protocol and verifies the returned call. [Apple dyld documentation](https://github.com/apple-oss-distributions/dyld/blob/main/doc/man/man1/dyld.1#L140-L153)

The host tool targets macOS 15.0 and the consumer targets macOS 13.0. Both run on arm64 macOS 27.0.1 with Apple Swift 6.4 and SDK 27.0. This uses configured CLI generation and the bundled Xcode parser. Packaged SwiftSyntax 600.0.1 parity, native plugin qualification, additional hosts, remaining artifact classes and signed release provenance retain their own gates.

## Recovery of the fixed SwiftPM generation paths

For DX-013, configured generation serializes cooperative writers with a lock on the plugin work-directory inode. It validates both destinations before changing either. Before replacing files, it stages a recovery journal containing the prior pair and the complete desired pair. The index temporarily contains an explicit Swift compiler error. The writer replaces the shard, checks its bytes, publishes the final index, verifies both files and removes the journal. A clean request with identical bytes skips publication.

A later valid generation inspects any retained journal. It recognizes complete previous or desired bytes, or restores the previous files before proceeding with the requested publication. `verify-generated` takes a read lock and reports `BPM004` for a retained journal without changing it. The two Swift paths are replaced individually and the dirty index blocks a consumer of the interrupted pair.

The macOS fixture obstructs the index destination and confirms rejection without replacing the shard. A separately compiled fault tool exercises six forward boundaries from before the journal write through after its removal. It also interrupts rollback after restoring the old shard, after restoring the old index and after removing the journal. The verifier checks exact output and journal bytes at every boundary. An installed journal produces `BPM004` even if both Swift files already match. Swift rejects the explicit dirty index where present. Without a journal, verification accepts the appropriate complete pair.

A normal retry produces the expected pair and clears the journal. When the desired pair is already complete, retry preserves both files' modification times. A further unchanged generation leaves them untouched. An input-set-only interruption and retry preserve the unchanged shard. The production plugin still declares exactly two generated Swift outputs.

With the native SwiftPM build backend and a prepared host artifact bundle, same-scratch retries stop the consumer after faults following the shard and final index writes. Each retry keeps the request unchanged and runs the updated typed `Int` mock. The retry after final index publication clears the journal while preserving both complete files. The first-publication fixture starts in a separate empty output directory. An interruption after the shard write leaves a dirty index and a journal that records both previous files as absent. Swift rejects the dirty index. An additional interruption after rollback removes both Swift files and leaves only the journal. In both states, `verify-generated` returns `BPM004` without changing the directory contents. Retrying the same inputs produces exactly the independently generated pair and removes the journal. A further unchanged request preserves the bytes and modification times.

The native SwiftPM fixture also starts in a fresh scratch directory, stops before running the consumer on its interrupted first build, and runs the typed `String` mock on an unchanged same-scratch retry. Its next build skips generation and preserves both files. These fixtures cover injected process exits around completed file operations.

The macOS contention fixture runs two configured CLI writers with distinct requests against the same work directory. The first writer pauses after replacing the shard. The second attempts the same directory lock without blocking and receives the kernel's would-block response before taking the normal waiting path. An inspection during the pause returns the expected plan and preserves the dirty shard, index and journal. After the first writer is released, the second observes the first request's independently generated complete pair before publishing its own. The final files match the independent second pair.

A separate run terminates the paused writer. Inspection and `verify-generated` preserve the interrupted files. `verify-generated` reports `BPM004` while the journal is present. A normal generation restores the complete pair. Interruption inside filesystem operations, power-loss durability, immutable directory selection, concurrent SwiftPM schedulers and other build backends and hosts remain open.

## Same-module protocol inheritance

GEN-002 now resolves transitive public Sendable protocols from an explicit same-module source index. The standalone `--source` arguments and the SwiftPM configuration entry share the resolver. The graph visits a diamond’s common declaration once. The generated endpoint identity stays rooted in the selected protocol, while inherited call reports point to the declaring file and line.

The compiled consumer calls the common witness through both parent existential views and verifies one typed descriptor with two returned calls. It also exercises an inherited property, typed async errors, and an unstubbed inherited call with its original source location. Reordered input files give byte-identical mock output. The configuration entry emits the same mock.

Missing, ambiguous and cyclic same-module parents stop generation with `BPM001`. Return-only and effect conflicts name both declaration sites. Failed requests preserve prior output. Independent equivalent signatures, imported interfaces and inherited actor isolation remain open.

The verification profile uses the installed Xcode parser and the existing SwiftPM consumer caches. Compilation of the exported tooling package, hosted distribution, and additional native qualification remain separate release gates.


## Read-only generation inspection

DX-003 adds `inspect` for the explicit source inputs and schema-1 configuration used by the SwiftPM generation entry. Generation and inspection resolve the same plan, including declaration validation and fixed output names. Inspection prints sorted schema-1 JSON with normalized inputs, selected declarations, planned ownership and the supplied-source feature gates. It preserves the selected sources and any existing generation outputs.

The CLI fixture compares the JSON before generation and after both files exist, with reordered sources and unchanged sources and outputs. Invalid configuration and unresolved inheritance fail with the same diagnostic families as generation. Full compiler context, includes, configured roots and native plugin profile qualification remain open.


## Generated-file drift verification

DX-011 adds the read-only `verify-generated` command for the SwiftPM-style generation request. It compares the planned shard and index byte for byte against the files in the supplied output directory. The check returns exit 3 and identifies every missing or edited file. The CLI fixture proves exact files pass, detects changed and missing files, and compares before and after project fingerprints. Manifest-owned cleanup and full output collision handling remain open.


## Inheritance from supplied dependency sources

GEN-002 now indexes explicit source inputs by Swift module and protocol name. A parent from another module requires an unconditional plain import in the file that declares the child. Bare parent names resolve within the declaring module, including when traversing a supplied dependency. The compiled consumer distinguishes the same-named protocols in two modules, exercises their typed setup and verification through existential views, and checks the original foreign module and file on an inherited invocation. The standalone and SwiftPM configuration entries generate the same mock.

The generator accepts ordinary instance methods with explicitly qualified Swift scalars in foreign parents. It rejects missing exact sources, duplicate parents, missing imports, ambiguous witness names and unsupported foreign types before publishing output. When a known imported declaration or selective import shadows a module qualifier, generation rejects that edge with its competing origin. A native compiler probe confirmed such an edge can bind a nested protocol whose default implementation allows an incorrect generated conformance to compile. Re-exports and unsupplied import scopes need compiler context. Textual or compiler-queried module interfaces remain under GEN-003. Broader signatures and inherited isolation also remain open.


## Concrete associated-type bindings

GEN-008 adds explicit scalar bindings to standalone generation. The resolver retains each direct inheritance edge and computes which associated names are visible in the declaring protocol. The emitter publishes a public value-type alias and concrete typed stubbing, mocking and verification APIs. The bound endpoint keeps the selected protocol identity and the original declaring file and line.

A separate SwiftPM consumer calls an `any AssociatedDirectory<String>` with the generated mock and verifies inherited and selected methods. The compiler rejects a stub with an `Int` result. `Element=String` and `Element=Swift.String` emit identical bytes. Missing, duplicate, conflicting, unknown or unsupported bindings, unrelated nominal names and collapsed overloads fail before replacing output.

Independent generic parameters, dependent same-type constraints, inherited parameterized parents and compiler-provided module interfaces remain open.


## Associated-type bindings in the SwiftPM configuration

A schema-1 selection accepts an optional `associatedTypeBindings` array of `name` and `type` records. The standalone flag and configured request use one validation path. Inspection reports the normalized concrete type. Drift verification and the build plugin use the same plan. A malformed binding record or conflicting values fail validation before the generator writes either output.

The isolated SwiftPM consumer uses the production build plugin with the Xcode-bundled parser executable in a local artifact bundle. The same consumer source builds and runs with `String` and `Int`, and changing only the configuration changes the mock shard and index. An unchanged run preserves both files. A conflict and an unchanged retry both fail a normal `swift run` before the consumer runs and preserve the bytes, paths and modification times of the last valid outputs. Restoring the valid configuration runs the consumer with those outputs.

Run `BLUEPRINT_VERIFY_CONFIGURED_BINDING_PLUGIN=1 python3 scripts/verify.py` to include this host lane. The packaged SwiftSyntax build, parity and additional native profiles remain separate checks.


## Associated types inherited from a supplied module

GEN-008 extends concrete bindings to module-qualified parents in supplied Swift sources. For a foreign requirement, the generator accepts a bare associated type only if its declaring protocol declares or inherits that name. A same-spelled nominal type on a sibling branch produces a diagnostic before either output is written.

The SwiftPM consumer binds `ParentDomain.BoundParent.Element` while generating a mock for `ConsumerDomain.AssociatedDirectoryFromDependency`. It calls through a constrained `any AssociatedDirectoryFromDependency<String>` existential and verifies typed calls. An unstubbed inherited call reports `ParentDomain/BoundParent.swift:5:1` and retains the selected protocol's endpoint identity. Missing and conflicting bindings identify the parent associated declaration and preserve the previous output. Configured generation emits the same witness as the standalone command.

The source profile covers known concrete scalars and ordinary instance methods. Dependent same-type constraints, implicit generic witnesses and interfaces obtained from compiled modules remain open.


## Concrete witnesses from parameterized protocol parents

GEN-008 now lowers a supplied parent specialization with one primary associated type and one explicitly qualified `Swift.Bool`, `Swift.Int` or `Swift.String` argument. Swift's inheritance syntax expresses a same-type requirement. The generator records that requirement before deduplicating parent visits, then checks it against explicit bindings before emitting any files. [Swift Evolution SE-0346](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md#constrained-protocols-in-desugared-positions)

The SwiftPM consumer builds `IntDirectory: ParentDomain.BoundParent<Swift.Int>` and calls through both `any IntDirectory` and `any ParentDomain.BoundParent<Int>`. The mock derives `Element` without a flag, a matching explicit binding gives identical bytes, and configured generation and inspection report the same concrete type. Inherited call reports retain `ParentDomain/BoundParent.swift:5:1`. Contradictory explicit bindings, conflicting inheritance paths and unsupported nested arguments produce diagnostics and preserve existing output.

Generic witnesses, multiple primary arguments, protocol-level where clauses, and compiler-provided module interfaces remain open.


## Dependent iterator equality after inherited primary normalization

The concrete GEN008-B fixture declares `Iterator.Element == Element` on a `Sendable` iterator associated type. `IntSequence: CursorSequence<Swift.Int>` resolves the primary `Element` binding. The explicit `Iterator=ConsumerDomain.IntCursor` binding is checked against a supplied non-generic public struct with direct `Swift.IteratorProtocol` and `Swift.Sendable` conformances and an unconditional public scalar `Element` type alias. The equality is checked before either generated output is written.

The independent SwiftPM consumer calls through `any IntSequence` and a generic `CursorSequence` function, invokes `next()` on the returned iterator, and verifies inherited call provenance. Configured inspection and standalone generation agree on the concrete bindings. A `String` specialization paired with the `Int` iterator fails at the equality and names the concrete alias location. The configured rejection preserves the generated shard and index. Missing source, inferred aliases and unqualified bindings are rejected. The verifier also rejects an extension through a type alias that shadows Swift inside the iterator and a source module name that the generated mock would shadow.

GEN-008 remains partial for generic witness generation, equivalence across arbitrary dependent members, multiple primary arguments, compiler-inferred and extension-provided witnesses, compiler-provided module interfaces, and packaged parser qualification.


## Explicit domain conditions for protocol members

The GEN004-A fixture supplies a Boolean for each reached custom `#if` flag under the source module that declares the requirement. The generator uses the selected member nodes for both type binding and emission, preserving source locations and emitting only the chosen witness. An omitted flag is diagnosed even when a different module supplies that flag or the domain supplies an unrelated one. The configured CLI rejects missing, conflicting or unsupported context before replacing the shard or index.

The independent SwiftPM fixture builds and runs the `Int` witness with `BLUEPRINT_DOMAIN_INT` defined only on `ConditionalDomain`. Removing that define alone makes native Swift reject the stale `Int` witness. Regeneration with the explicit false context then builds and runs the `String` witness in the same scratch directory using identical target sources, test-target settings and output paths. Run `BLUEPRINT_VERIFY_CONDITIONAL_CONSUMER=1 python3 scripts/verify.py` to include this fixture.

Automatic build-plugin discovery and its settings-only invalidation remain open. SwiftPM's `SwiftSourceModuleTarget.compilationConditions` provides the evaluated manifest compilation conditions. SwiftPM adds other Swift flags and compiler-generated defines separately, so omission from the plugin property cannot establish an effective false value. A complete source-target context and a tracked plugin command input for its changes are still required. [SwiftPM plugin context serializer](https://github.com/swiftlang/swift-package-manager/blob/swift-6.0-RELEASE/Sources/SPMBuildCore/Plugins/PluginContextSerializer.swift#L72-L85) · [SwiftPM compiler flags](https://github.com/swiftlang/swift-package-manager/blob/swift-6.0-RELEASE/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift#L796-L843)

Top-level conditionals, `#elseif`, compound or platform predicates, and broader compiler contexts remain open. DX-007 retains its native Xcode project qualification.

## macOS availability for typed result witnesses

The GEN004-B fixture declares an always-available `AvailabilityDirectory` protocol with a `receipt()` requirement and `NewReceipt` result struct that both start at macOS 14. The generator validates the shorthand introduction on the method and checks the same-module struct from supplied source. It uses the latest introduction from eligible active requirements on the entire mock class. The class boundary covers typed endpoints, nested stubs and verification, initializer signatures and witnesses. Swift rejects availability annotations on potentially unavailable stored properties. [Swift compiler availability tests](https://github.com/swiftlang/swift/blob/main/test/Availability/availability_versions.swift#L383-L402)

The independent SwiftPM consumer targets macOS 13. Its guarded test configures a typed return, calls through the protocol and verifies the returned invocation. The verifier requires a marker emitted after the guarded assertions execute on the host. Separate floor typechecks reject unguarded calls through the protocol, direct mock construction or escape, and references to both nested helpers. The protocol's baseline method stays usable with a floor-safe conformer. A control that leaves the witness annotated but removes the class boundary fails at the private typed endpoint. A two-method check confirms that swapping declaration order keeps the later version. Unsupported availability spellings and missing result declarations preserve standalone output. Configured generation also preserves the shard and index after an unsupported availability edit.

This evidence covers compilation for the macOS 13 deployment target and execution on the available newer macOS host. Execution on macOS 13, iOS, per-member mock availability, protocol-level and mixed-platform attributes, and qualification of the packaged parser remain open. The automatic SwiftPM compiler context and original Xcode project checks retain their own gates.


## Immediate nonescaping callback plans

RUN-011 and GEN-017 cover ordinary Sendable mocks with one final unary nonescaping callback on a synchronous, nonthrowing instance method. The external consumer verifies that an answer invokes the original callback during the admission, a return stub skips it, and the callback’s local payload is released after the call. Typed verification exposes only the ordinary arguments. Swift rejects passing the callback from the answer into escaping storage under nonisolated and MainActor default isolation.

Configured generation emits the same witness as the standalone CLI. Generator guards diagnose actor-isolated requirements, async effects, and a callback before the final position in this profile. The existing checked spy uses the same call-scoped runtime. Further callback shapes and applicable release profile certification remain open.

## Typed escaping callback capture

GEN-016 adds a final unary `@escaping @Sendable` callback to an ordinary, synchronous and nonthrowing instance method on a Sendable protocol supplied in the same module. The generated witness retains the callback type. Stubbing and verification match only ordinary arguments. A winning stub that opts into `EscapingCallbackCaptor` holds the closure outside the general journal. The typed handle exposes the originating admission and an explicit synchronous invocation with the callback's input and result types.

The separate SwiftPM consumer calls through the domain protocol, observes that the callback has not yet run, delivers a typed value after the method returns, and verifies the registration once. Shadowed, unmatched and noncapturing stubs leave no capture. Reset and finish release the held payload and their stale handles reject delivery. Compiler fixtures reject losing MainActor isolation, a non-Sendable capture and incorrectly typed replay. Configured CLI diagnostics for unsupported escaping forms preserve the previous shard and index.

Additional parameter shapes, direct spy forwarding, scheduled or one-shot delivery, cancellation, and child delivery events remain open. A delivery that acquired its closure before invalidation can finish. The checks use the Xcode-bundled parser and Swift 6 language mode on the available macOS host.


## MainActor escaping callback capture

GEN-016 also supports `@escaping @MainActor @Sendable` on the final unary parameter of a synchronous, nonthrowing method on a Sendable protocol. The generated witness preserves actor isolation and the method stays nonisolated. Supplied source declarations and imports that shadow the recognized actor spelling produce a diagnostic. The typed handle requires MainActor for replay. Both callback profiles use the same session storage and keep callback values out of ordinary matchers and history.

The independent SwiftPM consumer registers through the protocol from a detached task and explicitly awaits replay from a detached task. The callback confirms MainActor execution and reads and updates actor-isolated state. Swift rejects synchronous off-actor replay, including with MainActor default isolation. Reset and finish release stored payloads and invalidate prior handles. Unsupported configured signatures preserve the last valid shard and index.

Other global actors, actor-isolated protocols, and scheduled delivery remain open. Verification uses the prepared Xcode toolchain in Swift 6 language mode on macOS. Additional toolchain and platform profiles remain open.


## Typed-throwing escaping callback replay

GEN-016 supports one final nonisolated, synchronous `@escaping @Sendable` callback with a named typed failure on a synchronous, nonthrowing Sendable protocol method. The witness preserves the function signature. The runtime stores a checked thunk returning `Result<Output, Failure>` to keep generic typed-function metadata out of retained storage. Replay returns the typed value or throws the exact original failure. A stale handle calls its explicit unavailability mapping without invoking the released callback.

The independent SwiftPM consumer exercises a success, a declared failure, and a subsequent success after registration. The registration history retains one admission and one returned event. Reset and finish release the retained payload and invalidate old handles. Compiler fixtures reject a foreign typed error, replay without `try`, and a throwing stub for the nonthrowing registration. Configured generation publishes the checked witness and preserves prior artifacts on actor-plus-typed-throws, untyped throws, and explicit `throws(Never)` rejections.

The consumer executable with the replay path links for macOS 13. Execution on the available newer macOS host is separate from deployment-target verification. Additional callback effects, isolation combinations, scheduled delivery, and other qualified toolchain and platform profiles remain open.


## Asynchronous escaping callback replay

GEN-016 supports a final unary, nonisolated `@escaping @Sendable (Input) async -> Output` callback on a synchronous, nonthrowing Sendable protocol method. The witness captures the original function type through a winning rule. The typed handle acquires the callback under the session gate and awaits it in the caller's task after releasing the locks.

The independent SwiftPM consumer checks that both registrations return before replay begins. An actor-controlled gate confirms the replay suspends. Separate reset and finish cases clear the captor, release an idle payload, and reject new replays on both retired handles. The acquired replay still holds its payload, then returns the typed result when the gate opens and releases that payload. Session history records registrations, and the acquired replay can outlive quiescent finish. The compiler rejects synchronous replay.

Scheduled delivery, additional actor and effect combinations, and other qualified toolchain and platform profiles remain open.


## Async typed-throwing escaping callback replay

GEN-016 supports one final, unary, nonisolated `@escaping @Sendable (Input) async throws(DeclaredFailure) -> Output` callback on a synchronous, nonthrowing Sendable protocol requirement. The witness preserves the full callback signature. A checked async thunk returns `Result<Output, Failure>` in retained storage. Replay acquires it under the session gate, awaits outside the locks, and returns or throws the exact typed outcome.

The independent SwiftPM consumer uses an actor gate to suspend replay after registration. A callback acquired before reset returns its typed value after release. A callback acquired before quiescent finish still throws its declared failure. New attempts on old handles call the supplied `@Sendable` unavailability mapping once without invoking the callback. The mapper can read session state. Callback payloads retire and the replay leaves registration history unchanged. Swift rejects a foreign callback failure type. Configured generation verifies both generated files on success and preserves both when it rejects unsupported global actors, untyped throws, and explicit `Never`.

The consumer executable with the async typed replay path links for macOS 13 and executes on the available newer host. This leaves native execution on the floor and other qualification profiles open. Additional actor-isolated effects and callback shapes, scheduled delivery, and one-shot or cancellation policies remain open.


## MainActor asynchronous escaping callback replay

GEN-016 supports one final, unary, nonthrowing `@escaping @MainActor @Sendable (Input) async -> Output` callback on a synchronous, nonthrowing Sendable protocol requirement. The witness, capture store and replay method preserve MainActor isolation. Registration stores the callback without invoking it. A replay acquires the closure on MainActor before awaiting it in the caller's task.

The independent SwiftPM consumer registers and replays from detached tasks. The callback writes to MainActor-isolated state and asserts MainActor at entry and after an actor gate suspends it. In separate reset and quiescent finish cases, teardown clears the captor, releases idle payloads and rejects later acquisitions. A replay that has already acquired the closure can resume on MainActor and return its typed value after teardown. The replay does not create a mock invocation or block quiescent finish.

Swift rejects retyping the replay method as isolated to a different global actor under both tested default-isolation modes. Configured generation emits identical files for the bare and Swift-qualified MainActor spellings and preserves the existing pair on unsupported actor-and-throwing combinations. Support for additional global actors, scheduled delivery, and full native platform qualification remain open.


## MainActor typed-throwing escaping callback replay

GEN-016 supports a final, unary, synchronous `@escaping @MainActor @Sendable (Input) throws(DeclaredFailure) -> Output` callback on a synchronous, nonthrowing Sendable protocol method. The witness retains the full callback signature. The capture store holds a checked MainActor thunk returning `Result<Output, Failure>`. Replay acquires it under the session gate and executes it on MainActor outside the locks, preserving the callback's declared failure.

The independent SwiftPM consumer detaches registration and replay. The callback asserts MainActor isolation and returns the typed value or throws the exact declared error. Reset and quiescent finish release the retained payload and reject old handles. The caller's unavailability mapping executes on MainActor only for stale handles and can inspect the session. Replay leaves the registration history intact. Swift rejects foreign callback failure types and synchronous off-actor replay in both tested isolation modes.

Configured generation emits identical files for the bare and Swift-qualified MainActor spellings and leaves the prior pair unchanged on unsupported forms. The consumer executable links for macOS 13 and replays both outcomes on the newer host. Native execution at the deployment floor, other global actors, and scheduled delivery remain open.


## MainActor async typed-throwing escaping callback replay

GEN-016 supports a final, unary `@escaping @MainActor @Sendable (Input) async throws(DeclaredFailure) -> Output` callback on a synchronous, nonthrowing Sendable protocol method. The witness preserves the checked signature. Storage retains a MainActor-isolated async thunk returning `Result<Output, Failure>`. Replay acquires it on MainActor under the session gate and awaits it after releasing the locks.

The independent SwiftPM consumer registers and replays from detached tasks. An actor gate confirms suspension after registration. The callback asserts MainActor at entry and resumption, returning the typed value after reset in one case and throwing the exact original failure after finish in the other. Later attempts on stale handles run only the supplied mapper on MainActor. The mapper can inspect the session. Teardown releases idle payloads and an acquired replay releases its payload on completion. Replay leaves registration history unchanged.

Swift rejects a foreign error and retyping to a different global actor in both tested isolation modes. Configured generation verifies both files for either MainActor spelling and preserves them on unsupported declarations. The standalone consumer with this replay path links for macOS 13 and executes on the newer host. Additional actors and callback shapes, scheduled delivery, native execution at the deployment floor, and full qualification remain open.


## Single callback deliveries on the manual session clock

RUN-010 and RUN-024 now have a manual-clock scheduling path for a captured nonisolated synchronous nonthrowing callback. A request accepts typed input and returns a typed receipt. Zero delay runs immediately. A positive delay is relative to the clock reading at registration. Advance acquires due callbacks under the session gate in deadline order, then calls them outside the locks before returning. Reset and quiescent finish retire pending requests. A batch already acquired can finish even if one callback reenters teardown.

The independent SwiftPM consumer schedules against a nonzero clock reading. It checks the state one nanosecond before and at the deadline, then advances again and verifies the callback ran exactly once. Separate reset and finish tests check that pending receipts become unavailable, subsequent clock advances cannot invoke the callbacks, and stale handles reject registration. A same-deadline test reenters reset from the first acquired callback and verifies that the other acquired callback still runs while a later request retires. The tests use explicit advances and preserve ordinary call history apart from the reset they request.

Wider scheduling policies, child delivery events, other actor and effect profiles, and delayed sequence steps remain open.


## Cancelling a pending manual-clock callback

A scheduled delivery receipt is bound to its exact request and owning session. A cancellation and a clock advance compete for that request under the session gate. Successful cancellation removes queued work and records `.cancelled`. The removed request releases its captured input outside the lock. Cancellation returns false if acquisition, another cancellation, reset, or finish has already removed the request. The outcome of an acquired callback remains readable after it completes.

The independent SwiftPM consumer checks cancellation before the deadline, while a same-deadline batch is already acquired, and after reset and finish. A reentrant callback cannot cancel an acquired sibling and can cancel a later queued request. The tests use distinct sessions and new captures after reset with matching inputs and delays to show that old receipts have no effect on those requests. Subsequent advances leave completed receipts and invocation counts unchanged. All timing comes from the manual session clock.

One-shot duplicate policies across independent requests, open-ended repetition, child delivery events, and other actor and effect profiles remain open.


## Finite callback series on the manual clock

RUN-010 and RUN-024 now cover repeating a synchronous nonisolated escaping callback with the same typed input at a finite list of supplied delays. Registration validates all delays before enqueuing the series against a single manual clock reading. Empty lists schedule nothing. Zero delays run immediately outside the lock. The receipt preserves the supplied order for outcomes while a clock advance executes each acquired batch in deadline order.

The independent SwiftPM consumer starts at a nonzero elapsed time and proves there are no early calls at the nanosecond boundary. Equal and unsorted offsets produce exactly one typed value per occurrence. A callback cancels future slots while other slots already acquired by the same advance still deliver. An independently scheduled one-shot survives series cancellation. Reentrant reset and finish likewise retire future slots and leave the acquired batch intact. An invalid offset leaves the whole series unscheduled.

Open-ended repeats, scheduling for other actor and effect profiles, delayed sequence steps, and child delivery events remain open.


## Continuous-clock single callback delivery

RUN-010 and RUN-024 also cover one scheduled synchronous nonisolated escaping callback on a continuous session clock. Positive delays create a monotonic sleeper tied to the exact pending request. At or after the deadline, the sleeper must acquire the closure under the session gate. Cancellation, reset, finish, or session deallocation removes queued requests and cancels their sleepers. Acquired callbacks run outside the gate. Zero delay preserves immediate delivery.

The independent SwiftPM consumer samples monotonic time before scheduling and confirms the actual callback starts at or after the requested lower bound. The callback attempts cancellation while acquired, then finishes the session and retains its pending receipt until it returns the typed result. Far-future tests retire pending work through cancellation, reset, finish, or session deallocation without waiting for those deadlines. Existing manual-clock tests still cover exact deadlines and finite batches.

## Finite callback series on the continuous clock

RUN-010 and RUN-024 also cover a finite series of the same typed synchronous nonisolated callback on a continuous session clock. Offsets use one monotonic registration time. Zero offsets deliver inline. The session arms the earliest positive occurrence and acquires it under the gate at or after the deadline. After that occurrence publishes its outcome outside the gate, the session arms the next one. Equal deadlines follow supplied order within the series, and the receipt always reports outcomes in supplied order.

The independent SwiftPM consumer checks unsorted and equal deadlines against the monotonic registration lower bound. Reentrant cancellation, reset, and finish retire queued siblings at the same deadline while the acquired occurrence completes. A deallocation fixture verifies that every queued occurrence retires, including those still waiting for the first timer. Manual advances still acquire entire due batches. Continuous one-shot tests continue to cover exact-receipt cancellation and lifecycle behavior.

Open-ended repetition, one-shot duplicate policies across independent requests, scheduling for other actor and effect profiles, child delivery events, delayed sequence steps, and broader native qualification remain open.
