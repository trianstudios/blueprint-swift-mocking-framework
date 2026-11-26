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

def xcrun(*arguments):
    return subprocess.check_output(["xcrun", *arguments], text=True).strip()

def main():
    swift = Path(xcrun("--find", "swift"))
    swiftc = Path(xcrun("--find", "swiftc"))
    if any(not executable.is_absolute() or not os.access(executable, os.X_OK)
           for executable in (swift, swiftc)):
        raise RuntimeError("xcrun must select executable Swift and swiftc files")
    if swift.parent.resolve() != swiftc.parent.resolve():
        raise RuntimeError("xcrun selected Swift and swiftc from different toolchains")
    sdk = xcrun("--sdk", "macosx", "--show-sdk-path")
    sdk_version = xcrun("--sdk", "macosx", "--show-sdk-version")
    if not Path(sdk).is_dir():
        raise RuntimeError("xcrun must select an installed macOS SDK")
    deployment_target = (ROOT / "scripts/macos-deployment-target").read_text().strip()
    swift_environment = os.environ | {"SWIFT_EXEC": str(swiftc), "SDKROOT": sdk}
    swift_version = subprocess.check_output(
        [str(swift), "--version"], text=True, stderr=subprocess.STDOUT, env=swift_environment
    ).strip()
    compiler_version = subprocess.check_output(
        [str(swiftc), "--version"], text=True, stderr=subprocess.STDOUT, env=swift_environment
    ).strip()

    def run_swift(name, arguments, *, extra_environment=None, **expectations):
        return run(name, [swift, *arguments],
                   env=swift_environment | (extra_environment or {}), **expectations)

    matrix = ROOT / "Docs/Acceptance-Status.csv"
    with matrix.open(encoding="utf-8") as roadmap:
        rows = list(csv.DictReader(roadmap))
    ids = [row["Feature ID"] for row in rows]
    if len(ids) < 125 or len(ids) != len(set(ids)):
        raise ValueError("The acceptance roadmap must retain the original 125 unique contracts")
    source = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDomain/UserRepository.swift"
    generated = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/UserRepositoryMock.swift"
    generation_environment = swift_environment | {
        "BLUEPRINT_VERIFY_SWIFTC": str(swiftc),
        "BLUEPRINT_VERIFY_SDK_PATH": sdk,
    }
    run("generation", [
        "bash", "scripts/generate.sh", "--input", source, "--module", "ConsumerDomain",
        "--protocol", "UserRepository", "--output", generated], env=generation_environment)
    tool = ROOT / ".build/prototype-tooling/generate"
    baseline = generated.read_bytes()
    actor_source = source.with_name("MainActorDirectory.swift")
    actor_generated = generated.with_name("MainActorDirectoryMock.swift")
    run("main-actor-generation", generate(tool, actor_source, actor_generated, "MainActorDirectory"))
    actor_baseline = actor_generated.read_bytes()
    temp = ROOT / ".build/verification"
    temp.mkdir(parents=True, exist_ok=True)
    run("generation-repeat", generate(tool, source, temp / "Repeated.swift"))
    assert baseline == (temp / "Repeated.swift").read_bytes()
    actor_repeated = temp / "RepeatedMainActor.swift"
    run("main-actor-generation-repeat",
        generate(tool, actor_source, actor_repeated, "MainActorDirectory"))
    assert actor_baseline == actor_repeated.read_bytes()
    relocated = temp / "relocated"
    relocated.mkdir(exist_ok=True)
    relocated_source = relocated / source.name
    relocated_source.write_text(source.read_text().replace(
        "func greeting(for name: String)", "func   greeting( for name : String )"))
    run("generation-whitespace", generate(tool, relocated_source, temp / "Whitespace.swift"))
    assert baseline == (temp / "Whitespace.swift").read_bytes()
    expected_rejections = {
        "DescriptorCollision": r"Overloads that differ only by effects or result type",
    }
    for rejection in sorted((ROOT / "Fixtures/GeneratorRejections").glob("*.swift")):
        output = temp / "Rejected.swift"
        output.write_text("sentinel: preserve the previous generation\n")
        rejection_patterns = [r"BPM001", r":\d+:\d+: error:"]
        if rejection.stem in expected_rejections:
            rejection_patterns.append(expected_rejections[rejection.stem])
        run("reject-" + rejection.stem, generate(tool, rejection, output, rejection.stem),
            fails=True, patterns=rejection_patterns)
        assert output.read_text() == "sentinel: preserve the previous generation\n"
    run_swift("runtime-tests", ["test"], patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b"])
    run_swift("consumer-tests", ["test", "--package-path", "Fixtures/ProtocolConsumer"],
        patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b"])
    run_swift("consumer-demo", ["run", "--package-path", "Fixtures/ProtocolConsumer", "consumer-demo"],
        patterns=[r"PASS: generated protocol"])
    modules = Path(run_swift("consumer-bin-path", [
        "build", "--package-path", "Fixtures/ProtocolConsumer", "--show-bin-path"]).strip())
    patterns = {
        "MainActorAssertionAccess": r"main actor-isolated.*'wasCalled",
        "MainActorAsyncTransport": r"sending 'entry' risks causing data races",
        "MainActorStubbingAccess": r"main actor-isolated.*'display",
        "MainActorVerificationAccess": r"main actor-isolated.*'display",
        "MainActorWitnessAccess": r"main actor-isolated.*'display",
        "WrongResult": r"cannot convert value of type 'Int'",
        "WrongError": r"cannot convert value of type 'Other'",
        "GeneratedWrongError": r"cannot convert value of type 'UnrelatedError'",
        "AsyncAnswerForSync": r"cannot pass function of type.*async",
        "NonSendableCapture": r"capture of 'box'.*non-[Ss]endable",
        "SchemaMismatch": r"cannot find type 'BlueprintRuntimeSchemaV999'",
        "ThrowForSync": r"has no member 'willThrow'",
    }
    for fixture in sorted((ROOT / "Fixtures/CompileFailures").glob("*.swift")):
        compiler_stage = ["-typecheck"]
        diagnostic_patterns = [patterns[fixture.stem]]
        if fixture.stem == "MainActorAsyncTransport":
            # Swift checks unsafe region transfers during SIL generation.
            compiler_stage = ["-emit-sil", "-o", os.devnull]
            diagnostic_patterns.append(r"non-Sendable 'DirectoryEntry'-typed result.*main actor-isolated")
        compiler_command = [
            swiftc, "-swift-version", "6", "-target",
            f"{platform.machine()}-apple-macos{deployment_target}", "-sdk", sdk, *compiler_stage,
            "-I", modules,
        ]
        check_name = "compile-reject-" + fixture.stem
        run(check_name, [*compiler_command, fixture], env=swift_environment,
            fails=True, patterns=diagnostic_patterns)
        if fixture.stem in {"MainActorWitnessAccess", "MainActorStubbingAccess",
                            "MainActorVerificationAccess"}:
            run(check_name + "-DefaultIsolation",
                [*compiler_command, "-default-isolation", "MainActor", fixture],
                env=swift_environment, fails=True, patterns=diagnostic_patterns)
    run_swift("reporter-intentional-failure", [
        "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX022_intentionalReporterFailure"], fails=True,
        extra_environment={"BLUEPRINT_EXPECT_FAILURE": "1"},
        patterns=[r"ConsumerTests.swift:\d+", r"Expected exactly 1 calls; observed 0"])
    run("xctest-consumer", [sys.executable, "Fixtures/XCTestConsumer/verify.py"],
        env=swift_environment, timeout=600,
        patterns=[r"PASS: XCTest reports sync and async verification failures at their caller lines"])
    for label, flag in [("typed", "--missing"), ("sync", "--missing-sync")]:
        fatal_log = run(label + "-missing-terminates", [modules / "consumer-demo", flag],
                        fails=True, patterns=[r"MOCK ISSUE: No matching stub", r"Fatal error: No matching stub"])
        assert fatal_log.index("MOCK ISSUE:") < fatal_log.index("Fatal error:")
    run_swift("runtime-only-consumer", [
        "run", "--package-path", "Fixtures/RuntimeOnly", "RuntimeOnly"],
        patterns=[r"PASS: runtime-only consumer"])
    runtime_bin = Path(run_swift("runtime-only-bin-path", [
        "build", "--package-path", "Fixtures/RuntimeOnly", "--show-bin-path"]).strip())
    linkage = run("runtime-only-linkage", ["otool", "-L", runtime_bin / "RuntimeOnly"])
    assert not any(name in linkage for name in ["SwiftSyntax", "SwiftParser", "Testing.framework", "XCTest"])
    dependencies = json.loads(run_swift("runtime-dependencies", ["package", "show-dependencies", "--format", "json"]))
    assert dependencies.get("dependencies") == []
    runtime_sources = list((ROOT / "Sources/BlueprintMocking").glob("*.swift"))
    assert all("import Testing" not in p.read_text() and "import XCTest" not in p.read_text()
               and "import SwiftSyntax" not in p.read_text() for p in runtime_sources)
    profile = {
        "status": "prototype evidence, not release certification",
        "swift": swift_version,
        "swiftPath": str(swift),
        "swiftCompilerVersion": compiler_version,
        "swiftCompilerPath": str(swiftc),
        "languageMode": "6", "sdkPath": sdk,
        "sdkVersion": sdk_version,
        "executionOS": subprocess.check_output(["sw_vers"], text=True).strip(),
        "architecture": platform.machine(), "deploymentTarget": f"macOS {deployment_target}",
        "defaultIsolation": "compiler default (nonisolated); no upcoming feature flags",
        "parser": "SwiftParser/SwiftSyntax bundled with this exact Xcode toolchain",
        "generatedSHA256": hashlib.sha256(baseline).hexdigest(),
        "mainActorGeneratedSHA256": hashlib.sha256(actor_baseline).hexdigest(),
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
