#!/usr/bin/env python3
"""One entry point for the supported local prototype profile; no network dependencies."""
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "Evidence"
EVIDENCE.mkdir(exist_ok=True)
RESULTS = []

def run(name, command, *, fails=False, patterns=(), env=None, timeout=120):
    completed = subprocess.run(
        [str(x) for x in command], cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = completed.stdout
    (EVIDENCE / (name + ".log")).write_text(output)
    valid = (completed.returncode != 0) if fails else (completed.returncode == 0)
    valid = valid and all(re.search(pattern, output) for pattern in patterns)
    RESULTS.append({"check": name, "passed": bool(valid), "exit": completed.returncode,
                    "expected_failure": fails, "log": name + ".log"})
    print(("PASS " if valid else "FAIL ") + name, flush=True)
    if not valid:
        print(output[-10000:], flush=True)
        raise RuntimeError(name)
    return output

def generate(tool, source, output, selected="UserRepository"):
    return [tool, "--input", source, "--module", "ConsumerDomain",
            "--protocol", selected, "--output", output]

def main():
    matrix = ROOT / "Docs/Acceptance-Status.csv"
    with matrix.open(encoding="utf-8") as roadmap:
        rows = list(csv.DictReader(roadmap))
    ids = [row["Feature ID"] for row in rows]
    if len(ids) < 125 or len(ids) != len(set(ids)):
        raise ValueError("The acceptance roadmap must retain the original 125 unique contracts")
    source = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDomain/UserRepository.swift"
    generated = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/UserRepositoryMock.swift"
    run("generation", [
        "bash", "scripts/generate.sh", "--input", source, "--module", "ConsumerDomain",
        "--protocol", "UserRepository", "--output", generated])
    tool = ROOT / ".build/prototype-tooling/generate"
    baseline = generated.read_bytes()
    temp = ROOT / ".build/verification"
    temp.mkdir(parents=True, exist_ok=True)
    run("generation-repeat", generate(tool, source, temp / "Repeated.swift"))
    assert baseline == (temp / "Repeated.swift").read_bytes()
    relocated = temp / "relocated"
    relocated.mkdir(exist_ok=True)
    relocated_source = relocated / source.name
    relocated_source.write_text(source.read_text().replace(
        "func greeting(for name: String)", "func   greeting( for name : String )"))
    run("generation-whitespace", generate(tool, relocated_source, temp / "Whitespace.swift"))
    assert baseline == (temp / "Whitespace.swift").read_bytes()
    for rejection in sorted((ROOT / "Fixtures/GeneratorRejections").glob("*.swift")):
        output = temp / "Rejected.swift"
        output.write_text("sentinel: preserve the previous generation\n")
        run("reject-" + rejection.stem, generate(tool, rejection, output, rejection.stem),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:"])
        assert output.read_text() == "sentinel: preserve the previous generation\n"
    run("runtime-tests", ["swift", "test"], patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b"])
    run("consumer-tests", ["swift", "test", "--package-path", "Fixtures/ProtocolConsumer"],
        patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b"])
    run("consumer-demo", ["swift", "run", "--package-path", "Fixtures/ProtocolConsumer", "consumer-demo"],
        patterns=[r"PASS: generated protocol"])
    modules = Path(run("consumer-bin-path", [
        "swift", "build", "--package-path", "Fixtures/ProtocolConsumer", "--show-bin-path"]).strip())
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    patterns = {
        "WrongResult": r"cannot convert value of type 'Int'",
        "WrongError": r"cannot convert value of type 'Other'",
        "GeneratedWrongError": r"cannot convert value of type 'UnrelatedError'",
        "AsyncAnswerForSync": r"cannot pass function of type.*async",
        "NonSendableCapture": r"capture of 'box'.*non-[Ss]endable",
        "SchemaMismatch": r"cannot find type 'BlueprintRuntimeSchemaV999'",
        "ThrowForSync": r"has no member 'willThrow'",
    }
    for fixture in sorted((ROOT / "Fixtures/CompileFailures").glob("*.swift")):
        run("compile-reject-" + fixture.stem, [
            "xcrun", "swiftc", "-swift-version", "6", "-target",
            platform.machine() + "-apple-macos15.0", "-sdk", sdk, "-typecheck",
            "-I", modules, fixture], fails=True, patterns=[patterns[fixture.stem]])
    intentional_env = os.environ.copy()
    intentional_env["BLUEPRINT_EXPECT_FAILURE"] = "1"
    run("reporter-intentional-failure", [
        "swift", "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX022_intentionalReporterFailure"], fails=True, env=intentional_env,
        patterns=[r"ConsumerTests.swift:\d+", r"Expected exactly 1 calls; observed 0"])
    for label, flag in [("typed", "--missing"), ("sync", "--missing-sync")]:
        fatal_log = run(label + "-missing-terminates", [modules / "consumer-demo", flag],
                        fails=True, patterns=[r"MOCK ISSUE: No matching stub", r"Fatal error: No matching stub"])
        assert fatal_log.index("MOCK ISSUE:") < fatal_log.index("Fatal error:")
    run("runtime-only-consumer", [
        "swift", "run", "--package-path", "Fixtures/RuntimeOnly", "RuntimeOnly"],
        patterns=[r"PASS: runtime-only consumer"])
    runtime_bin = Path(run("runtime-only-bin-path", [
        "swift", "build", "--package-path", "Fixtures/RuntimeOnly", "--show-bin-path"]).strip())
    linkage = run("runtime-only-linkage", ["otool", "-L", runtime_bin / "RuntimeOnly"])
    assert not any(name in linkage for name in ["SwiftSyntax", "SwiftParser", "Testing.framework", "XCTest"])
    dependencies = json.loads(run("runtime-dependencies", ["swift", "package", "show-dependencies", "--format", "json"]))
    assert dependencies.get("dependencies") == []
    runtime_sources = list((ROOT / "Sources/BlueprintMocking").glob("*.swift"))
    assert all("import Testing" not in p.read_text() and "import XCTest" not in p.read_text()
               and "import SwiftSyntax" not in p.read_text() for p in runtime_sources)
    profile = {
        "status": "prototype evidence, not release certification",
        "swift": subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT).strip(),
        "languageMode": "6", "sdkPath": sdk,
        "sdkVersion": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(),
        "executionOS": subprocess.check_output(["sw_vers"], text=True).strip(),
        "architecture": platform.machine(), "deploymentTarget": "macOS 15.0",
        "defaultIsolation": "compiler default (nonisolated); no upcoming feature flags",
        "parser": "SwiftParser/SwiftSyntax bundled with this exact Xcode toolchain",
        "generatedSHA256": hashlib.sha256(generated.read_bytes()).hexdigest(),
        "acceptanceContractCount": len(rows),
    }
    (EVIDENCE / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")

exit_status = 0
try:
    main()
except Exception as error:
    print("Verification failed: " + str(error), file=sys.stderr)
    exit_status = 1
finally:
    (EVIDENCE / "results.json").write_text(json.dumps(RESULTS, indent=2) + "\n")
if exit_status:
    sys.exit(exit_status)
print("All prototype checks passed; evidence is in Evidence/results.json.", flush=True)
