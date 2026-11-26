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


if __name__ == "__main__":
    main()
