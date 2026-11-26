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

Every mapped contract remains partial; all other contracts remain visible as unimplemented. This is one local compiler/SDK/OS profile, with no release certification or performance claim. The manifests' macOS 15 target does not establish execution support on that older OS. No fallback synchronization backend, platform matrix, or packaged SwiftSyntax dependency has been certified.

The second milestone adds a generated MainActor mock for GEN-035 and RUN-020. It uses actor-local storage for non-Sendable inputs and outputs, and preserves the actor boundary in setup, matchers, sync and typed async answers, and verification. A suspended async answer keeps its invocation identity, and a reentrant matcher sees the same verification prefix throughout the assertion. The runtime suite has 13 tests and the external consumer has 6. The compiler fixtures reject cross-isolation witness, setup, descriptor, and assertion access. Explicit nonisolated callers still fail with MainActor default isolation enabled. The SIL fixture rejects returning a non-Sendable reference across the actor boundary. Custom global actors and Actor-constrained conformers remain to be implemented.

Introduce session-coordinated identities and lifecycle invariants before implementing live revisions/reset or cross-mock ordering (SYS-007, RUN-014, RUN-034, RUN-036, RUN-042). The original matrix remains the completion definition.
