# Protocol mocking implementation evidence

The target is Blueprint Mocking Full Product Architecture edition 1.0 (6 October 2026), especially A2.2, A3.1, R1.1–R1.2, R2.1, R4.1, and R5.1–R5.2. The public roadmap retains all 125 acceptance contracts. The architecture's Mockingbird comparison is a historical design benchmark, not a current compatibility or superiority claim.

## Changes

| Location | Implemented behavior |
| --- | --- |
| Package.swift | Runtime-only dependency graph; optional Swift Testing reporting product |
| Sources/BlueprintMocking/Runtime.swift | Typed sync and async-throwing endpoints, immutable setup, checked Sendable journals, matchers, count verification, neutral issues |
| Sources/BlueprintMockingTesting/Reporter.swift | Swift Testing issue reporting using the verification caller's source location |
| Tooling/GenerateMocks.swift | SwiftParser frontend, restricted validated declarations, sorted endpoint identities, witness/setup/verification emission |
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

## Timed session assertions

RUN-031, RUN-032 and RUN-033 have local evidence for sustained metadata counts. The session assigns elapsed time and ordinal in the same event transaction. The observer replays retained events in order and returns the last included watermark at an exclusive deadline. Manual-clock fixtures cover a brief violation between wakes, a restarted window, equal-time events, cancellation, early finish, reset, and unavailable history. The generated-mock consumer exercises the public API using a specific endpoint and completion phase. The current timed API supports session-owned manual and continuous clocks. Richer timeout diagnostics, immutable argument and result projections, and certification across supported profiles remain open.

## Projection and certification evidence

Sendable synchronous and async-throwing endpoints can retain typed argument and result projections. Public SwiftPM consumers verify pending publication, immutable copies after raw mutation, weak references after deallocation, thrown and optional results, and detached completion across reset. Immediate verification returns captures only for a complete successful assertion. Consuming verification publishes a typed capture bundle when the scope claim commits. The standalone generator now supports explicit projection selectors for Sendable synchronous nonthrowing and async-throwing methods. Its external SwiftPM consumer calls the projected mock through the protocol and exercises typed history, mutation, pending data and detached reset. Sendable synchronous and async-throwing stubs support winning-rule captures through generated and direct endpoints. Async captures follow successful reservation and preserve the admitted configuration revision across replacement. Consumer fixtures cover competing and negated rules, reentrant matchers and captors, concurrent admission, reset, stale publication, and release outside locks. String argument stability for direct projected Sendable endpoints uses admission and publication timestamps to distinguish pending and settled intervals. String result stability uses the terminal event's timestamp and treats a typed throw as a settled non-return. The generated verification surface also exposes String argument and result stability. The external fixture proves an argument window, rejects a pending result as incomplete, and proves the fresh result after reset. Other effect and isolation profiles and richer temporal predicates remain open.

For RUN-006, `xcrun swift test --filter 'RUN006'` exercises equality versus identity, optional matching, and typed case extraction in both Sendable and MainActor fixtures. The pre-Mutex iOS probe in `scripts/verify_apple_deployment.py` also exercises equality, identity, and typed case projection on the available iOS 17.5 simulator. These runs provide scoped evidence. Native execution on the remaining applicable Apple, Ubuntu, and Windows profiles and review of the exact applicable profile plan remain required.

For SYS-008, `python3 -m unittest discover -s scripts/tests -p 'test_check_release.py'` checks that otherwise valid evidence cannot certify a completed row with a missing source reference, check name, or required profile result. The unit bundle uses synthetic profile metadata. Certification requires a reviewed plan covering the applicable release-validation hosts and actual evidence tied to the exact Git revision.

The [candidate release profile plan](Release-Profile-Plan.md) lists the reproduced profiles, native executions still required, and evidence fields for review.

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
