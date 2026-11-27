#!/usr/bin/env python3
"""Verify configured generic method validation, inspection, and standalone parity."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from verify_inspection import OUTPUT_NAMES, require_unchanged, sha256, snapshot


MODULE = "ConsumerDomain"
GENERIC = "GenericMethodDirectory"
FIELD = "genericMethodSpecializations"
SELECTOR = "transform(_:)"
REPORT = "generic-method-config-report.json"
SOURCE_DIRECTORY = Path("Fixtures/ProtocolConsumer/Sources/ConsumerDomain")
RAW_ID = f"schema1|{MODULE}.{GENERIC}|transform<T:Swift.Hashable&Swift.Sendable>(_:T)->T|Sendable"


def specialization(type_name, selector=SELECTOR):
    return {"selector": selector, "type": type_name}


def selection(name):
    return {"module": MODULE, "type": name, "kind": "protocol"}


def write_config(path, selected):
    data = {"schemaVersion": 1, "selections": [selected]}
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def verify(tool, repository, evidence):
    checks = {}

    def run(label, *arguments, diagnostic=None):
        result = subprocess.run([tool, *arguments], capture_output=True, timeout=30, check=False)
        artifacts = {}
        for suffix, data in (("stdout", result.stdout), ("stderr", result.stderr)):
            artifact = evidence / f"generic-method-config-{label}.{suffix}"
            artifact.write_bytes(data)
            artifacts[artifact.name] = sha256(data)
        checks[label] = {"exit": result.returncode, "artifacts": artifacts}
        if diagnostic is None:
            accepted = result.returncode == 0 and not result.stderr
        else:
            accepted = result.returncode == 1 and not result.stdout and re.search(diagnostic, result.stderr)
        if not accepted:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise ValueError(f"{label}: unexpected exit {result.returncode}: {detail}")
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="Generic Method Configuration ", dir=evidence) as temporary:
        staged = Path(temporary)
        sources = staged / "Swift Sources"
        sources.mkdir()
        generic = sources / f"{GENERIC}.swift"
        ordinary = sources / "UserRepository.swift"
        for source in (generic, ordinary):
            source.write_bytes((repository / SOURCE_DIRECTORY / source.name).read_bytes())
        config = staged / "blueprint-mocking.json"
        output = staged / "Generated Swift"
        request = [
            "--config", config, "--output", output, "--input-set-id", "128",
            "--source", MODULE, generic, "--source", MODULE, ordinary,
        ]

        write_config(config, selection("UserRepository"))
        run("seed-ordinary-pair", "generate", *request)
        seed = snapshot(output)
        before = snapshot(staged)
        old_plan = json.loads(run("inspect-ordinary", "inspect", *request, "--format", "json"))
        require_unchanged(staged, before, "inspect-ordinary")
        old_selection, = old_plan["configuration"]["selections"]
        old_declaration, = old_plan["declarations"]
        if FIELD in old_selection or any("specialization" in row for row in old_declaration["endpoints"]):
            raise ValueError("Ordinary inspection included generic-only fields")

        authored = selection(GENERIC) | {FIELD: [specialization("String"), specialization("Swift.Int")]}
        normalized = selection(GENERIC) | {FIELD: [specialization("Swift.Int"), specialization("Swift.String")]}
        write_config(config, authored)
        before = snapshot(staged)
        inspected = run("inspect-specializations", "inspect", *request, "--format", "json")
        require_unchanged(staged, before, "inspect-specializations")
        plan = json.loads(inspected)
        if plan["configuration"] != {"schemaVersion": 1, "selections": [normalized]}:
            raise ValueError("Inspection did not canonicalize both specialization choices")
        declaration, = plan["declarations"]
        origin = str(generic.relative_to(config.parent))
        if (declaration["file"], declaration["line"], declaration["generatedType"]) != (origin, 1, GENERIC + "Mock"):
            raise ValueError("Inspection misplaced the generic protocol declaration")
        shared_origin = {"id": RAW_ID, "module": MODULE, "file": origin, "line": 2, "column": 5}
        expected_endpoints = [
            shared_origin | {"specialization": type_name}
            for type_name in ("Swift.Int", "Swift.String")
        ]
        if declaration["endpoints"] != expected_endpoints:
            raise ValueError("Endpoint inspection must retain the raw ID and distinguish specialization and origin")

        run("generate-specializations", "generate", *request)
        if set(path.name for path in output.iterdir()) != set(OUTPUT_NAMES) or snapshot(output) == seed:
            raise ValueError("Configured generation did not replace the prior pair with specialized output")
        standalone = staged / "Standalone.swift"
        run("standalone-parity", "--input", generic, "--module", MODULE, "--protocol", GENERIC,
            "--output", standalone, "--specialize-method", SELECTOR + "=Int",
            "--specialize-method", SELECTOR + "=String")
        shard = (output / OUTPUT_NAMES[0]).read_bytes()
        index = (output / OUTPUT_NAMES[1]).read_bytes()
        header = b"// Generated by Blueprint Mocking. Do not edit.\n"
        prefix = header + standalone.read_bytes()
        marker = re.fullmatch(rb"\nenum (BlueprintMockingShard_[0-9a-f]+) \{\}\n", shard[len(prefix):])
        if not shard.startswith(prefix) or marker is None or b"typealias Shard = " + marker[1] not in index:
            raise ValueError("Configured shard, index, and standalone specialized witness differ")

        reordered = selection(GENERIC) | {FIELD: [specialization("Int"), specialization("Swift.String")]}
        write_config(config, reordered)
        before = snapshot(staged)
        replayed = run("inspect-equivalent-choices", "inspect", *request, "--format", "json")
        require_unchanged(staged, before, "inspect-equivalent-choices")
        if replayed != inspected:
            raise ValueError("Equivalent option spellings or ordering changed canonical inspection")
        run("generate-equivalent-choices", "generate", *request)
        require_unchanged(staged, before, "generate-equivalent-choices")
        verified = run("verify-exact-pair", "verify-generated", *request)
        require_unchanged(staged, before, "verify-exact-pair")
        if verified != b"Blueprint Mocking: verified 2 generated file(s)\n":
            raise ValueError("The specialized pair did not verify exactly")

        wrong_shape = rb"^error: BPM002: [^\n]*genericMethodSpecializations"
        duplicate = rb"GenericMethodDirectory\.swift:\d+:\d+: error: BPM001: Duplicate generic method specialization"
        invalid_configurations = (
            ("null", None, wrong_shape),
            ("object", specialization("Int"), wrong_shape),
            ("scalar-entry", ["Int"], wrong_shape),
            ("missing-key", [{"selector": SELECTOR}], wrong_shape),
            ("unknown-key", [specialization("Int") | {"extra": True}], wrong_shape),
            ("nonstring-selector", [{"selector": 7, "type": "Int"}], wrong_shape),
            ("nonstring-type", [{"selector": SELECTOR, "type": 7}], wrong_shape),
            ("duplicate-equivalent", [specialization("Int"), specialization("Swift.Int")], duplicate),
        )
        for label, choices, diagnostic in invalid_configurations:
            write_config(config, selection(GENERIC) | {FIELD: choices})
            before = snapshot(staged)
            for verb in ("generate", "verify-generated"):
                run(f"{label}-{verb}", verb, *request, diagnostic=diagnostic)
                require_unchanged(staged, before, f"{label}-{verb}")

    report = evidence / REPORT
    report.write_text(json.dumps({"checks": checks}, indent=2) + "\n", encoding="utf-8")
    print(f"EVIDENCE: {report.name} SHA-256 {sha256(report.read_bytes())}")
    print("PASS: GEN010 configured inspection identifies each typed specialization")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    try:
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / REPORT).unlink(missing_ok=True)
        verify(options.tool.resolve(strict=True), Path(__file__).resolve().parents[1], evidence)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Generic method configuration verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
