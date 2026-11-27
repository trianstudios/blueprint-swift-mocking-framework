#!/usr/bin/env python3
"""Run two native Xcode test schemes against explicit source-target conditions."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from unicodedata import normalize


FIXTURE = Path(__file__).resolve().parent
ADAPTER = FIXTURE.parents[1] / "scripts/xcode/blueprint-build-phase.sh"
OUTPUTS = ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")
GENERATION = "Blueprint Mocking: generated 1 protocol mock(s)"
MEMBERSHIP = "files = (C00000000000000000000025);"
ADDED_MEMBER = "files = (C00000000000000000000025, C00000000000000000000037);"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def stage(work, args):
    root = work / "Original Project é"
    shutil.copytree(FIXTURE / "template", root)
    tools = root / "Tools"
    tools.mkdir()
    shutil.copy2(args.adapter, tools / "Run Génération.sh")
    shutil.copy2(args.tool, tools / "blueprint-generate")
    runtime = root / "PreparedRuntime"
    runtime.mkdir()
    shutil.copy2(args.runtime_products / "BlueprintMocking.o", runtime / "BlueprintMocking.o")
    shutil.copytree(args.runtime_products / "BlueprintMocking.swiftmodule",
                    runtime / "BlueprintMocking.swiftmodule")
    return root


def verify(args):
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="Native contexts é ", dir=args.evidence_dir.resolve()))
    print(f"DX007 native evidence directory {work}", flush=True)
    root = stage(work, args)
    project = root / "Native Context.xcodeproj"
    derived = work / "Derived Data é"
    xcodebuild = args.developer_dir / "usr/bin/xcodebuild"
    environment = os.environ.copy() | {"DEVELOPER_DIR": str(args.developer_dir.resolve())}
    results = {}

    def test(label, scheme, result_type, *, generates=True, diagnostic=None):
        command = [
            "/usr/bin/nice", "-n", "10", xcodebuild, "-project", project, "-scheme", scheme,
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", derived,
            "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-parallel-testing-enabled", "NO",
            "-jobs", "1", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "test",
        ]
        log = work / f"{label}.log"
        with log.open("wb") as handle:
            process = subprocess.run(command, env=environment, stdout=handle, stderr=subprocess.STDOUT,
                                     check=False, timeout=180)
        data = log.read_bytes()
        text = data.decode(errors="replace")
        results[label] = {"exit": process.returncode, "log": log.name, "sha256": digest(data)}
        if diagnostic:
            require(process.returncode != 0 and diagnostic in text and GENERATION not in text,
                    f"{label}: expected source-context rejection. See {log}")
        else:
            require(process.returncode == 0 and (GENERATION in text) == generates,
                    f"{label}: unexpected Xcode result {process.returncode}. See {log}")
            require(f"PASS: DX007 native {result_type}" in text and
                    re.search(r"Executed 1 test, with 0 failures", text) is not None,
                    f"{label}: the real typed XCTest did not pass. See {log}")
        print(f"PASS: Xcode original project {label}", flush=True)
        return text

    def state(scheme):
        output = derived / f"Build/Intermediates.noindex/Native Context.build/{scheme}/PhaseContextTests.build/Blueprint"
        return {name: ((output / name).read_bytes(), (output / name).stat().st_mtime_ns) for name in OUTPUTS}

    test("native-numbers", "Numbers", "Int")
    numbers = state("Numbers")
    test("native-words", "Words", "String")
    words = state("Words")
    require(state("Numbers") == numbers, "Building Words changed the Numbers output")
    for expected, snapshots in ((b"Int", numbers), (b"String", words)):
        shard = snapshots[OUTPUTS[0]][0]
        require(re.search(rb"func lookup\(key input: (?:Swift\.)?String\) -> (?:Swift\.)?" + expected, shard),
                "The generated shard did not carry its compiled configuration-specific witness")
    require(numbers[OUTPUTS[1]][0] != words[OUTPUTS[1]][0],
            "The index did not carry the configuration-specific shard marker")

    test("native-numbers-again", "Numbers", "Int", generates=False)
    require(state("Numbers") == numbers, "An unchanged test build touched its generated outputs")

    # Change actual source-target membership and the explicit generator input list together.
    project_file = project / "project.pbxproj"
    input_list = root / "Source Lists/BlueprintInputs.xcfilelist"
    project_contents, inputs = project_file.read_bytes(), input_list.read_bytes()
    require(project_contents.count(MEMBERSHIP.encode()) == 1, "The original domain Sources phase was ambiguous")
    support = root / "Services/Support é.swift"
    support.write_text("public struct ExtraMembership: Sendable {}\n", encoding="utf-8")
    try:
        project_file.write_bytes(project_contents.replace(MEMBERSHIP.encode(), ADDED_MEMBER.encode()))
        input_list.write_bytes(inputs + f"$(SRCROOT)/Services/{support.name}\n".encode())
        compilation = test("domain-source-added", "Numbers", "Int")
        require(any("SwiftCompile" in line and support.name in normalize("NFC", line).replace("\\ ", " ")
                    for line in compilation.splitlines()),
                "Xcode did not compile the newly added native domain source")
        expanded = state("Numbers")
        require(expanded[OUTPUTS[0]] == numbers[OUTPUTS[0]] and expanded[OUTPUTS[1]][0] != numbers[OUTPUTS[1]][0],
                "Native source membership change did not update only the generated index")
        require(state("Words") == words, "Updating Numbers rewrote the other configuration")
    finally:
        project_file.write_bytes(project_contents)
        input_list.write_bytes(inputs)
        support.unlink()

    test("domain-source-removed", "Numbers", "Int")
    restored = state("Numbers")
    require(restored[OUTPUTS[0]] == numbers[OUTPUTS[0]] and restored[OUTPUTS[1]][0] == numbers[OUTPUTS[1]][0],
            "Removing the source did not restore the original canonical outputs")

    # A consumer configuration defines BLUEPRINT_DOMAIN_INT in Words. Removing
    # the explicit source request must still fail before either generated file changes.
    invocation = b'--source-condition PhaseDomain BLUEPRINT_DOMAIN_INT \\"$condition\\"'
    require(project_contents.count(invocation) == 1, "Cannot isolate the explicit source CLI context")
    try:
        project_file.write_bytes(project_contents.replace(invocation, b""))
        test("missing-explicit-domain-context", "Words", "String",
             diagnostic="Missing compilation condition 'BLUEPRINT_DOMAIN_INT' for source module 'PhaseDomain'")
        require(state("Words") == words, "Failed context left modified Words outputs")
    finally:
        project_file.write_bytes(project_contents)
    test("native-words-after-restore", "Words", "String", generates=True)
    require(state("Words") == words, "Restoring its context rewrote the Words outputs")

    record = {
        "xcode": subprocess.check_output([xcodebuild, "-version"], env=environment, text=True,
                                         timeout=20).splitlines(),
        "runtimeObjectSHA256": digest((root / "PreparedRuntime/BlueprintMocking.o").read_bytes()),
        "hostToolSHA256": digest((root / "Tools/blueprint-generate").read_bytes()),
        "adapterSHA256": digest((root / "Tools/Run Génération.sh").read_bytes()),
        "outputs": {scheme: {name: digest(data) for name, (data, _) in snapshots.items()}
                    for scheme, snapshots in (("Numbers", numbers), ("Words", words))},
        "results": results,
    }
    body = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    report = work / "xcode-context-report.json"
    report.write_bytes(body)
    print(f"SHA256 {digest(body)} {report.name}")
    print("PASS: DX007 two native Xcode test schemes use explicit source-target conditions and membership")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--developer-dir", required=True, type=Path)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--runtime-products", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--adapter", type=Path, default=ADAPTER)
    args = parser.parse_args()
    try:
        verify(args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
