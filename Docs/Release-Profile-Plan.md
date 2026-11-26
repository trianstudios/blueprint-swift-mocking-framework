# Candidate release profile plan for RUN-006 and SYS-008

Draft for maintainer review. Both contracts remain Partial in the [acceptance registry](Acceptance-Status.csv). This plan applies the architecture's exact profile requirements (D2.2), platform targets (D2.3) and evidence rules (D4.2) to two contracts. Implementation evidence for a specific host does not change the release scope.

## RUN-006 · Equality, identity, and optional matchers

The acceptance gate requires equal-but-distinct objects and identical objects to produce different matches. The six `RUN006` tests also cover nested optionals, typed enum case extraction that skips the payload matcher on the wrong case, and non-Sendable payload matching on MainActor. Run them with `swift test --filter RUN006`, using the reviewed compiler. Run the equivalent contract fixture with an appropriate runner on device and simulator targets. [Matcher tests](../Tests/BlueprintMockingTests/MatcherCompositionTests.swift)

| Applicable runtime scope | Evidence already observed | Remaining execution evidence |
| --- | --- | --- |
| Apple · macOS 13 floor and contemporary macOS | All six matcher tests passed on arm64 macOS 27.0.1 (26A434) with Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), SDK 27.0 and Swift Testing 2084. The package floor is macOS 13. The test runner reports `arm64e-apple-macos14.0`. | Run on macOS 13 with arm64 and run floor and current x86_64 lanes where advertised. Select a floor-compatible runner or a runnable contract probe. |
| Apple · iOS 16, tvOS 16, watchOS 9 and visionOS 1 floors, plus contemporary versions | Apple SDK 27 links the runtime at these floors. A Swift 6 standalone probe built for the arm64 iOS 16 simulator target executes the matcher cases and NSLock path on iOS 17.5. | Run the contract on the exact floors and selected current simulator and device profiles. The iOS 17.5 probe does not establish iOS 16 execution, physical device coverage, or coverage for the other Apple runtimes. |
| Linux · Ubuntu 22.04 and 24.04, each on x86_64 and arm64 | The pinned offline runtime check passed all six matcher tests on Ubuntu 24.04.5 LTS arm64, Swift 6.4.3 (`swift-6.4.3-RELEASE`), target `aarch64-unknown-linux-gnu`, with Swift Testing 6.4.3 (`ba0861fb203553c`), at revision `08503581035f6b8be00113e7063c5777236143ab`. | Run the same fixtures natively on Ubuntu 22.04 arm64 and x86_64, and Ubuntu 24.04 x86_64. Record the distribution build, toolchain, runner and container digest if used. |
| Windows · Windows 10 x64 and maintained Windows 11 x64 image | No native run recorded. | On both Windows profiles, run the matcher fixtures using the selected official Swift toolchain, Windows SDK and compatible test runner. |

RUN-006 uses the runtime without generation, so separate macOS generator host variants do not add RUN-006 profiles. The reviewer must choose exact current OS builds, target architectures and simulator/device combinations, including the intended x86_64 macOS scope. On a floor that cannot run the selected test library, require a standalone executable exercising equivalent matcher assertions and capture its exit and output. Cross-linking verifies deployment compatibility at build time. [Apple floor verifier](../scripts/verify_apple_deployment.py) · [Linux runtime verifier](../scripts/verify_linux_runtime.sh)

## SYS-008 · Traceable completion evidence

Run `python3 scripts/tests/test_check_release.py -v` on each supported release-evaluation host. The 12 tests passed with Python 3.13.3 on arm64 macOS 27.0.1. They include complete rows with valid artifacts and missing implementation references or named checks, missing required-profile evidence, and a control row whose evidence passes. The revisions and profile records inside the tests are fixtures. Capture the actual test process result for release evidence. [Checker tests](../scripts/tests/test_check_release.py)

Proposed minimal scope is the actual host that evaluates the release bundle. The checker is a Python command, separate from the deployed Swift runtime. Review must establish whether it is supported on additional macOS, Linux or Windows release-evaluation hosts. If advertised there, run the suite on those exact host OS and architecture tuples with the reviewed Python versions. Record the evaluator and the Swift candidate profile it checks separately. Apple device and simulator execution belongs to runtime contracts such as RUN-006.

## Evidence by source revision

| Run | Source binding | Observed scope |
| --- | --- | --- |
| Public SwiftPM install on arm64 macOS | Resolved revision `5296b29a49633a925cbfef118da748c15cf4f019` in the package lockfiles | Runtime-only, Swift Testing and XCTest consumers passed. |
| Apple floor and simulator checks around `5296b29` | Workspace logs recorded the toolchain but no full source hash | Apple SDK 27 linked all declared deployment targets. The iOS 17.5 simulator probe exercised selected matcher and fallback-lock checks. |
| Offline Ubuntu 24.04.5 arm64 | Archived revision `08503581035f6b8be00113e7063c5777236143ab` | Swift 6.4.3 ran the runtime and archived consumer fixtures, including all six RUN-006 tests. |
| Ubuntu arm64 rerun requested at `5296b29a49633a925cbfef118da748c15cf4f019` | Requested revision only | The container engine failed before the workload ran. The earlier Ubuntu result remains tied to its archived revision. |

The macOS verifier records `sourceRevision` only when it can identify the repository root and both endpoint checks of the working tree are clean at the same revision. It records the before and after checks even for a dirty checkout. Compare the results SHA-256 in `Evidence/profile.json` with `Evidence/results.json` and retain the per-check log hashes. This is provenance for a local run. The reviewed certification bundle still needs all required exact profiles and equivalent gates.

Concrete instance subscripts support variadic indices (GEN-024). Generated Sendable variadic method adapters take array-based providers (GEN-020). Generic and type-level subscripts and variadic accessor forwarding remain implementation gaps. Separate native Apple execution, Ubuntu 22.04 and x86_64 runs, and Windows x64 runs are profile gaps. [Acceptance registry](Acceptance-Status.csv)

## Evidence bundle and review

1. For each applicable profile, record the exact compiler and SwiftSyntax line or its inapplicability, host OS/build and architecture, SDK or container, target and minimum deployment, Swift 6 language mode, default isolation, feature flags, and test runner. Record the target execution OS/build separately from the build host when they differ. For SYS-008 record the Python version and the candidate Swift language mode. Where compiler, SwiftSyntax, isolation or SDK fields do not apply to the check, record that explicitly in their required string fields.
2. At the selected full source revision, execute the reviewed checks and keep their logs. Use consistent result names per contract across profiles. A result may come from a platform-specific runner if it exercises the same reviewed assertions. The schema checks the same named evidence for every required profile, so linking and execution results must remain distinct. Repeat prior runs at the candidate revision and retain the runner output.
3. Outside the evaluated source commit, write a schema-1 plan with `revision`, `profiles`, and `contracts`. Each contract includes the verbatim `acceptance_gate`, its `required_profiles`, and a mapping to relative artifact paths and SHA-256 digests. Each artifact binds `feature_id`, the same gate and full revision, the full profile, and results with unique `check`, `passed`, `exit`, and `expected_failure` fields. Registry implementation references stay relative to the source tree.
4. Have a reviewer confirm that the profiles and passing checks cover the original gate, then validate the candidate registry with `python3 scripts/check_release.py --registry CANDIDATE.csv --certification PLAN.json --revision FULL_SOURCE_HASH --json`. The checker validates an input bundle's consistency and hashes. Execution, profile coverage and producer provenance require review. A valid but incomplete release registry still returns exit 1 in strict mode.

[Release checker and field definitions](../scripts/check_release.py)
