# Contributing to Blueprint Mocking

Use Swift 6 language mode and a macOS Xcode toolchain that provides SwiftParser and SwiftSyntax. Run the verification suite from the repository root with `python3 scripts/verify.py`. It builds the generated doubles and runs the runtime, consumer, and rejection fixtures. See the [README](README.md) for the tested profile and standalone SwiftPM commands.

1. Choose a contract from the [acceptance roadmap](Docs/Acceptance-Status.csv). Include its ID in the pull request, and describe which behavior and toolchain profile your change covers.
2. Write a focused failing test first. Use a runtime test for stub or verification behavior, a consumer fixture for generated code, or a rejection fixture for a Swift compiler diagnostic. Run the test and confirm that it fails for the intended reason.
3. Implement the smallest change that passes the new test, then refactor as needed. Run `python3 scripts/verify.py` and update the acceptance roadmap with the evidence and any remaining gaps.
4. Commit and push each verified milestone as a coherent change. For contributions, push to your branch or fork and open a pull request with the failing and passing test evidence.

Keep runtime behavior, code generation, and test runner reporting in their existing modules. Source specifications and local build evidence are outside the public tree. Include concise reproduction steps and sanitized diagnostics when reporting a failure.

To check the roadmap with its current evidence, run `python3 scripts/check_release.py --report-only`.
Run `python3 scripts/check_release.py` as the strict release gate. It returns a failure until every original
contract has an implementation and passing evidence for all of its required profiles. The script documents the
certification plan and artifact format. A reviewer must confirm that the planned profiles and checks satisfy the
acceptance gate before trusting a certification report.

Run the signed candidate gate from the trusted build before any release publication. Use the candidate tag, external evidence archive and runner-owned key policy defined in the [release profile plan](Docs/Release-Profile-Plan.md#signed-candidate-gate). The command returns success only for strict readiness.
