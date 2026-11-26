#!/usr/bin/env python3
"""Exercise the optional XCTest reporter from an external Swift 6 consumer."""
import os
from pathlib import Path
import re
import subprocess

FIXTURE = Path(__file__).resolve().parent
ROOT = FIXTURE.parents[1]
TESTS = FIXTURE / "Tests/XCTestConsumerTests"


def run(*command, env=None):
    result = subprocess.run(
        command, cwd=ROOT, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
    )
    print(result.stdout, end="")
    return result


def test(swift, test_name, env):
    return run(swift, "test", "--package-path", str(FIXTURE), "--filter", test_name, env=env)


def xcrun(*arguments):
    return subprocess.check_output(["xcrun", "--sdk", "macosx", *arguments], text=True).strip()


def main():
    swift = xcrun("--find", "swift")
    swiftc = xcrun("--find", "swiftc")
    sdk = xcrun("--show-sdk-path")
    environment = os.environ.copy()
    environment.update({
        "BLUEPRINT_VERIFY_SWIFTC": swiftc,
        "BLUEPRINT_VERIFY_SDK_PATH": sdk,
        "SWIFT_EXEC": swiftc,
        "SDKROOT": sdk,
    })
    environment.pop("BLUEPRINT_XCTEST_EXPECT_FAILURE", None)
    environment.pop("BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE", None)
    environment.pop("BLUEPRINT_XCTEST_ORPHAN_MODE", None)
    generated = run(
        "bash", "scripts/generate.sh",
        "--input", str(FIXTURE / "Sources/LookupDomain/Lookup.swift"),
        "--module", "LookupDomain", "--protocol", "Lookup",
        "--output", str(TESTS / "LookupMock.swift"),
        env=environment,
    )
    if generated.returncode:
        raise SystemExit("XCTest fixture generation failed")

    passing = test(swift, "ReporterTests.testPassingVerificationDoesNotRecordAnIssue", environment)
    if passing.returncode or not re.search(
        r"testPassingVerificationDoesNotRecordAnIssue.*passed", passing.stdout
    ):
        raise SystemExit("Passing XCTest fixture did not run successfully")

    environment["BLUEPRINT_XCTEST_EXPECT_FAILURE"] = "1"
    sources = (TESTS / "ReporterTests.swift").read_text().splitlines()
    for kind, cardinality in (("sync", 1), ("async", 2)):
        invocation_line, = (
            number for number, source in enumerate(sources, 1)
            if source.endswith("// expected XCTest failure: " + kind)
        )
        runner = test(swift, f"ReporterTests.testMismatchReports{kind.capitalize()}Caller", environment)
        message = f"Expected exactly {cardinality} calls; observed {cardinality - 1}"
        pattern = rf"ReporterTests\.swift:{invocation_line}:\s+error:.*{re.escape(message)}"
        if runner.returncode == 0 or len(re.findall(pattern, runner.stdout)) != 1:
            raise SystemExit(f"XCTest {kind} failure was not attributed to ReporterTests.swift:{invocation_line}")
    print("PASS: XCTest reports sync and async verification failures at their caller lines")

    late = test(swift, "LateTaskReporterTests.testLateTypeScopeTaskKeepsOwningReporter", {
        **environment, "BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE": "1",
    })
    expected_late_issue = (
        r"error: .*testLateTypeScopeTaskKeepsOwningReporter.*Lookup\.swift:\d+: Cannot call "
        r"schema1\|LookupDomain\.Lookup\|type:subscript:[^\n]+\.set[^\n]+ in a finished mock session"
    )
    if (late.returncode == 0 or len(re.findall(expected_late_issue, late.stdout)) != 1
            or not re.search(r"Executed 1 test, with 1 failure \(0 unexpected\)", late.stdout)
            or "PASS: DX023 late type task retained its owning reporter" not in late.stdout):
        raise SystemExit("XCTest late type task did not retain its owning session reporter")
    print("PASS: XCTest late type task retained its owning reporter")

    # Runtime discovery must include the suite so its observation hook sees the live run.
    environment.pop("BLUEPRINT_XCTEST_EXPECT_FAILURE", None)
    lookup = FIXTURE / "Sources/LookupDomain/Lookup.swift"
    setter_line, = (line for line, text in enumerate(lookup.read_text().splitlines(), 1)
                    if text.strip().startswith("static subscript(_ slot:"))
    owner_failure = (
        r"Cannot call schema1\|LookupDomain\.Lookup\|type:subscript:[^\n]+\.set[^\n]+"
        r" in a finished mock session"
    )
    for mode, count in (("wrong-owner", 1), ("suite", 1), ("overflow", 2)):
        runner = run(swift, "test", "--package-path", str(FIXTURE), "--disable-swift-testing",
                     env={**environment, "BLUEPRINT_XCTEST_ORPHAN_MODE": mode})
        native_errors = re.findall(r"(?m)^.*:\d+:\s+error:.*$", runner.stdout)
        case_a = "BLUEPRINT XCTEST CASE FINISHED -[OrphanSuiteReporterTests testAOwnerSchedulesOrphan] failures=0"
        start_b = "BLUEPRINT XCTEST CASE STARTED -[OrphanSuiteReporterTests testBPeerFlushesIntoTheSuite]"
        case_b = ("BLUEPRINT XCTEST CASE FINISHED -[OrphanSuiteReporterTests testBPeerFlushesIntoTheSuite] "
                  f"failures={1 if mode == 'wrong-owner' else 0}")
        suite_end = f"BLUEPRINT XCTEST SUITE FINISHED OrphanSuiteReporterTests failures={count}"
        batch_checked = "PASS: Blueprint XCTest verified orphan owner, source and one-time batch"
        sequence = [runner.stdout.find(marker) for marker in (case_a, start_b, batch_checked, case_b, suite_end)]
        if runner.returncode != 1 or len(native_errors) != count or min(sequence) < 0 or sequence != sorted(sequence):
            raise SystemExit(f"XCTest orphan run did not reproduce the expected case and suite counts ({mode})")
        if mode == "wrong-owner":
            expected = (r"error: .*OrphanSuiteReporterTests testBPeerFlushesIntoTheSuite.*"
                        rf"Lookup\.swift:{setter_line}: {owner_failure}")
        else:
            expected = rf"Lookup\.swift:{setter_line}:\s+error: OrphanSuiteReporterTests\s+:\s+{owner_failure}"
        if sum(re.search(expected, line) is not None for line in native_errors) != 1:
            raise SystemExit(f"XCTest orphan diagnostic lost its source location or destination ({mode})")
        suite_issues = runner.stdout.count("BLUEPRINT XCTEST SUITE ISSUE OrphanSuiteReporterTests ")
        if suite_issues != (0 if mode == "wrong-owner" else count):
            raise SystemExit(f"XCTest orphan run observed the wrong number of suite issues ({mode})")
        if mode == "overflow" and not any("Blueprint Mocking lost orphan failure records (1 dropped)" in line
                                          for line in native_errors):
            raise SystemExit("XCTest orphan flush did not report the dropped failure summary")
    print("PASS: XCTest routes buffered orphan failures to the suite")


if __name__ == "__main__":
    main()
