#!/usr/bin/env python3
"""Exercise read-only SwiftPM inspection and generated-output verification."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


SOURCE_DIRECTORY = Path("Fixtures/ProtocolConsumer/Sources/ConsumerDomain")
MODULE = "ConsumerDomain"
ROOT_PROTOCOL = "InheritedDirectory"
BASE_PROTOCOL = "InheritedDirectoryRoot"
BRANCHES = ("InheritedDirectoryReadBranch", "InheritedDirectoryWriteBranch")
INPUT_SET = "a01d"
OUTPUT_NAMES = ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(directory):
    entries = {}
    for path in [directory, *directory.rglob("*")]:
        details = path.lstat()
        content = sha256(path.read_bytes()) if stat.S_ISREG(details.st_mode) else None
        entries[str(path.relative_to(directory))] = (
            details.st_mode, details.st_ino, details.st_size, details.st_mtime_ns, content,
        )
    return entries


def fixture(repository, directory):
    project = directory / "Config With Spaces"
    internal = project / "Swift Sources"
    external = directory / "Adjacent Sources"
    internal.mkdir(parents=True)
    external.mkdir()
    sources = {}
    for name in (*BRANCHES, ROOT_PROTOCOL, BASE_PROTOCOL):
        filename = f"{name}.swift"
        target = (external if name == BASE_PROTOCOL else internal) / filename
        target.write_bytes((repository / SOURCE_DIRECTORY / filename).read_bytes())
        sources[name] = target
    configuration = project / "blueprint-mocking.json"
    select = [{"module": MODULE, "type": name, "kind": "protocol"} for name in (BASE_PROTOCOL, ROOT_PROTOCOL)]
    configuration.write_text(json.dumps({"schemaVersion": 1, "selections": select}) + "\n", encoding="utf-8")
    (project / "Handwritten.txt").write_text("not tooling output\n", encoding="utf-8")
    return configuration, sources


def arguments(configuration, output, inputs):
    result = ["--config", str(configuration), "--output", str(output), "--input-set-id", INPUT_SET]
    for path in inputs:
        result += ["--source", MODULE, str(path)]
    return result


def invoke(tool, evidence, label, request, records, *, verb="inspect"):
    options = ["--format", "json"] if verb == "inspect" else []
    result = subprocess.run(
        [str(tool), verb, *request, *options], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=False,
    )
    artifacts = {}
    for name, data in (("stdout", result.stdout), ("stderr", result.stderr)):
        path = evidence / f"inspection-{label}.{name}"
        path.write_bytes(data)
        artifacts[path.name] = sha256(data)
    records[label] = {"exit": result.returncode, "artifacts": artifacts}
    return result


def require_unchanged(directory, before, label):
    after = snapshot(directory)
    different = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    if different:
        raise ValueError(f"{label}: read-only command altered staged paths {different}")


def expected_plan(configuration, output, sources):
    project = configuration.parent

    def reporting_path(path):
        return str(path.relative_to(project)) if path.is_relative_to(project) else str(path)

    selected = [
        {"module": MODULE, "type": name, "kind": "protocol"} for name in (ROOT_PROTOCOL, BASE_PROTOCOL)
    ]
    declaration_lines = (1, 5)
    inherited = [
        ("fetch(id:Int) async throws(InheritedDirectoryFailure)->String", BASE_PROTOCOL, 7),
        ("label(for:String)->String", BASE_PROTOCOL, 6),
        ("mark(_:String)->Void", BASE_PROTOCOL, 8),
    ]
    endpoint_specs = {
        ROOT_PROTOCOL: inherited + [
            ("identify()->String", ROOT_PROTOCOL, 2),
            ("property:revision.get->Int", BRANCHES[0], 2),
            ("rename(to:String)->String", BRANCHES[1], 2),
        ],
        BASE_PROTOCOL: inherited,
    }

    def endpoints(name):
        return [
            {
                "id": f"schema1|{MODULE}.{name}|{signature}|Sendable",
                "module": MODULE,
                "file": reporting_path(sources[declared_on]),
                "line": line,
                "column": 25 if signature.startswith("property:") else 5,
            }
            for signature, declared_on, line in sorted(endpoint_specs[name])
        ]

    return {
        "schemaVersion": 1,
        "configuration": {"schemaVersion": 1, "selections": selected},
        "inputSetID": INPUT_SET,
        "inputs": {
            "configuration": configuration.name,
            "sources": [
                {"module": MODULE, "path": path} for path in sorted(map(reporting_path, sources.values()))
            ],
        },
        "declarations": [
            entry | {
                "file": reporting_path(sources[entry["type"]]), "line": line, "generatedType": entry["type"] + "Mock",
                "endpoints": endpoints(entry["type"]),
            } for entry, line in zip(selected, declaration_lines, strict=True)
        ],
        "outputOwnership": {
            "owner": "BlueprintMockingBuildPlugin",
            "files": [reporting_path(output / name) for name in OUTPUT_NAMES],
        },
        "featureGates": {
            "analysis": "supplied-swift-sources",
            "compilerContext": "unavailable",
            "protocolInheritance": "supplied-source-index",
        },
    }


def verify_generated(tool, evidence, staged, request, checks, label, *, drift=()):
    before = snapshot(staged)
    result = invoke(tool, evidence, label, request, checks, verb="verify-generated")
    require_unchanged(staged, before, label)
    if not drift:
        success = b"Blueprint Mocking: verified 2 generated file(s)\n"
        if result.returncode != 0 or result.stderr or result.stdout != success:
            raise ValueError(f"{label}: exact outputs must verify successfully")
    else:
        diagnostic = result.stderr.decode("utf-8", errors="replace").splitlines()
        expected = ["error: BPM003: Generated files differ:", *map(str, drift)]
        if result.returncode != 3 or result.stdout or [line.strip() for line in diagnostic] != expected:
            raise ValueError(f"{label}: wrong drift diagnostic or exit status {result.returncode}: {diagnostic}")
    print(f"PASS: DX011 {label} preserves authored/generated state", flush=True)


def verify_source_membership(tool, evidence, staged, output, request, checks):
    shard, index = (output / name for name in OUTPUT_NAMES)
    stable = snapshot(output)
    unrelated = staged / "Adjacent Sources" / "Unselected.swift"
    unrelated.write_text("public struct Unselected: Sendable {}\n", encoding="utf-8")
    expanded = request + ["--source", "UnselectedDomain", str(unrelated)]

    verify_generated(tool, evidence, staged, expanded, checks, "verify-expanded-source-set", drift=(index,))
    generated = invoke(tool, evidence, "generate-expanded-source-set", expanded, checks, verb="generate")
    expanded_outputs = snapshot(output)
    if (generated.returncode != 0 or expanded_outputs[shard.name] != stable[shard.name]
            or expanded_outputs[index.name][4] == stable[index.name][4]):
        raise ValueError("Changing supplied source membership must change only the generated index")

    unrelated.write_text("public struct\n", encoding="utf-8")
    verify_generated(tool, evidence, staged, expanded, checks, "verify-unselected-edit")
    generated = invoke(tool, evidence, "generate-unselected-edit", expanded, checks, verb="generate")
    if generated.returncode != 0 or snapshot(output) != expanded_outputs:
        raise ValueError("Generation parsed an unrelated module or rewrote its unchanged output")

    unrelated.unlink()
    for verb in ("inspect", "generate", "verify-generated"):
        label = f"{verb}-missing-listed-source"
        before = snapshot(staged)
        failed = invoke(tool, evidence, label, expanded, checks, verb=verb)
        require_unchanged(staged, before, label)
        diagnostic = (
            f"error: BPM002: Missing supplied Swift source in module UnselectedDomain: {unrelated}\n"
        ).encode()
        if failed.returncode != 1 or failed.stdout or failed.stderr != diagnostic:
            raise ValueError(f"{label}: expected a missing listed source diagnostic, got {failed.returncode}")

    verify_generated(tool, evidence, staged, request, checks, "verify-reduced-source-set", drift=(index,))
    generated = invoke(tool, evidence, "generate-reduced-source-set", request, checks, verb="generate")
    restored = snapshot(output)
    if (generated.returncode != 0 or restored[shard.name] != stable[shard.name]
            or restored[index.name][4] != stable[index.name][4]):
        raise ValueError("Removing unrelated membership must restore the original index bytes and keep the shard")
    print("PASS: DX012 source membership validates listed files and updates only index provenance", flush=True)


def verify(tool, repository, evidence):
    checks = {}
    with tempfile.TemporaryDirectory(prefix="Read Only Inspection ", dir=evidence) as temporary:
        staged = Path(temporary)
        configuration, sources = fixture(repository, staged)
        output = configuration.parent / "Generated Swift"
        request = arguments(configuration, output, sources.values())
        plan = expected_plan(configuration, output, sources)
        before = snapshot(staged)
        fresh = invoke(tool, evidence, "fresh", request, checks)
        require_unchanged(staged, before, "fresh")
        if fresh.returncode != 0 or fresh.stderr or json.loads(fresh.stdout) != plan or output.exists():
            raise ValueError("Fresh inspection did not produce the expected read-only plan")
        print("PASS: DX003 fresh inspection plan and output absence", flush=True)

        shard, index = (output / name for name in OUTPUT_NAMES)
        verify_generated(tool, evidence, staged, request, checks, "verify-missing-directory", drift=(shard, index))

        generated = invoke(tool, evidence, "prepare-generated", request, checks, verb="generate")
        if generated.returncode != 0 or {path.name for path in output.iterdir()} != set(OUTPUT_NAMES):
            raise ValueError("Normal generation did not prepare the two owned outputs")
        (output / "Existing Handwritten.swift").write_text("enum HandWritten {}\n", encoding="utf-8")
        reordered = [f"{path.parent}/./{path.name}" for path in reversed(tuple(sources.values()))]
        before = snapshot(staged)
        warm = invoke(tool, evidence, "warm", arguments(configuration, output, reordered), checks)
        require_unchanged(staged, before, "warm")
        if warm.returncode != 0 or warm.stderr or warm.stdout != fresh.stdout:
            raise ValueError("Inspection changed with reordered path spellings or prepared generated outputs")
        print("PASS: DX003 warm inspection is byte-identical and preserves generated files", flush=True)
        verify_generated(tool, evidence, staged, request, checks, "verify-exact")
        verify_generated(tool, evidence, staged, arguments(configuration, output, reordered),
                         checks, "verify-reordered-source-spellings")
        verify_source_membership(tool, evidence, staged, output, request, checks)

        incomplete = [path for name, path in sources.items() if name != BASE_PROTOCOL]
        cases = [(
            "missing-inherited-source",
            arguments(configuration, output, incomplete),
            rb"InheritedDirectoryReadBranch\.swift:1:\d+: error: BPM001: Missing inherited protocol "
            rb"ConsumerDomain\.InheritedDirectoryRoot in the supplied source inputs",
        )]
        bad_configuration = configuration.with_name("unknown-key.json")
        raw = json.loads(configuration.read_bytes())
        bad_configuration.write_text(json.dumps(raw | {"unknownKey": True}) + "\n", encoding="utf-8")
        absent = configuration.parent / "Absent Invalid Output"
        cases.append((
            "unknown-config-key",
            arguments(bad_configuration, absent, sources.values()),
            rb"error: BPM002: Expected schemaVersion and selections.*unknown-key\.json",
        ))
        for label, argv, diagnostic in cases:
            before = snapshot(staged)
            rejected = invoke(tool, evidence, label, argv, checks)
            require_unchanged(staged, before, label)
            if rejected.returncode == 0 or rejected.stdout or not re.search(diagnostic, rejected.stderr):
                raise ValueError(f"{label}: expected a focused diagnostic and empty stdout")
            print(f"PASS: DX003 {label} preserves authored/generated state", flush=True)

        original_shard = shard.read_bytes()
        edited_shard = original_shard + b"// Hand edit to an owned mock.\n"
        shard.write_bytes(edited_shard)
        verify_generated(tool, evidence, staged, request, checks, "verify-edited-shard", drift=(shard,))
        shard.write_bytes(original_shard)
        index.unlink()
        verify_generated(tool, evidence, staged, request, checks, "verify-missing-index", drift=(index,))
        shard.write_bytes(edited_shard)
        verify_generated(tool, evidence, staged, request, checks, "verify-combined-drift", drift=(shard, index))

    report = evidence / "inspection-report.json"
    report.write_text(json.dumps({"checks": checks}, indent=2) + "\n", encoding="utf-8")
    print(f"EVIDENCE: {report.name} SHA-256 {sha256(report.read_bytes())}")
    print("PASS: DX003 read-only inspection", flush=True)
    print("PASS: DX011 verify-generated drift checks", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    try:
        repository = Path(__file__).resolve().parent.parent
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "inspection-report.json").unlink(missing_ok=True)
        verify(options.tool.resolve(strict=True), repository, evidence)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Inspection verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
