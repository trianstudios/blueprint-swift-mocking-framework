#!/usr/bin/env python3
"""Verify resolved endpoint identities and origins through the configured CLI."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


MODULE = "InspectionDomain"
PARENT_MODULE = "InspectionSupport"
PROTOCOL = "Directory"
INPUT_SET = "126"
REPORT = "endpoint-inspection-report.json"
SHARD = "BlueprintMocks.generated.swift"
INDEX = "BlueprintMockingIndex.generated.swift"
ENDPOINT = re.compile(rb'EndpointID\("([^"\\]+)"\)')
DIRECTORY_SOURCE = """\
import InspectionSupport

public protocol Directory: InspectionSupport.DirectoryParent, Sendable {
    func lookup(for key: String) -> String
}
"""
PARENT_SOURCE = """\
public protocol DirectoryParent: Sendable {
    func rank(_ value: Swift.Int) -> Swift.Int
}
"""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(directory):
    entries = {}
    for path in (directory, *directory.rglob("*")):
        details = path.lstat()
        contents = sha256(path.read_bytes()) if stat.S_ISREG(details.st_mode) else None
        entries[str(path.relative_to(directory))] = (
            details.st_mode, details.st_size, details.st_mtime_ns, contents,
        )
    return entries


def expected_endpoints(root, configuration, parent, *, moved=False, asynchronous=False):
    def row(signature, module, file, line, column):
        return {
            "id": f"schema1|{MODULE}.{PROTOCOL}|{signature}|Sendable",
            "module": module,
            "file": file,
            "line": line,
            "column": column,
        }

    effect = " async" if asynchronous else ""
    return [
        row(f"lookup(for:String){effect}->String", MODULE,
            str(root.relative_to(configuration.parent)), 5 if moved else 4, 9 if moved else 5),
        row("rank(_:Swift.Int)->Swift.Int", PARENT_MODULE, str(parent), 2, 5),
    ]


def verify(tool, evidence):
    checks = {}
    cases = {}

    def invoke(label, command, request, directory):
        stdout_path = evidence / f"endpoint-inspection-{label}.stdout"
        stderr_path = evidence / f"endpoint-inspection-{label}.stderr"
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            result = subprocess.run(
                [tool, command, *request], cwd=directory,
                stdout=stdout, stderr=stderr, timeout=45, check=False,
            )
        stdout, stderr = stdout_path.read_bytes(), stderr_path.read_bytes()
        checks[label] = {
            "exit": result.returncode,
            "stdout": stdout_path.name,
            "stdoutSHA256": sha256(stdout),
            "stderr": stderr_path.name,
            "stderrSHA256": sha256(stderr),
        }
        if result.returncode != 0 or stderr:
            raise ValueError(f"{label}: unexpected CLI exit or diagnostics. See {stderr_path}")
        return stdout

    with tempfile.TemporaryDirectory(prefix="Endpoint Inspection ", dir=evidence) as temporary:
        staged = Path(temporary)
        project = staged / "Consumer Project"
        selected_directory = project / "Swift Sources"
        parent_directory = staged / "Adjacent Source"
        selected_directory.mkdir(parents=True)
        parent_directory.mkdir()
        root = selected_directory / "Directory.swift"
        parent = parent_directory / "DirectoryParent.swift"
        root.write_text(DIRECTORY_SOURCE, encoding="utf-8")
        parent.write_text(PARENT_SOURCE, encoding="utf-8")

        configuration = project / "blueprint-mocking.json"
        configuration.write_text(json.dumps({
            "schemaVersion": 1,
            "selections": [{"module": MODULE, "type": PROTOCOL, "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = project / "Generated Swift"
        sources = [(MODULE, root), (PARENT_MODULE, parent)]

        def request(order):
            arguments = ["--config", str(configuration), "--output", str(output), "--input-set-id", INPUT_SET]
            for module, path in order:
                arguments.extend(["--source", module, str(path)])
            return arguments

        def inspect(label, order, expected):
            before = snapshot(staged)
            raw = invoke(label, "inspect", [*request(order), "--format", "json"], staged)
            if snapshot(staged) != before:
                raise ValueError(f"{label}: inspect altered the authored inputs or generated outputs")
            report = json.loads(raw)
            declarations = report.get("declarations")
            if not isinstance(declarations, list) or len(declarations) != 1 or not isinstance(declarations[0], dict):
                raise ValueError(f"{label}: expected one resolved declaration in the configured inspect report")
            declaration = declarations[0]
            if (declaration.get("module"), declaration.get("type")) != (MODULE, PROTOCOL):
                raise ValueError(f"{label}: inspection returned the wrong selected declaration")
            if "endpoints" not in declaration:
                raise ValueError(f"{label}: configured inspect report is missing declarations[0].endpoints")
            if declaration["endpoints"] != expected:
                raise ValueError(f"{label}: incorrect endpoint IDs or declaration origins: {declaration['endpoints']!r}")
            cases[label] = {"endpoints": declaration["endpoints"], "inspectionSHA256": sha256(raw)}
            return raw

        def require_generated_matches(label, order, expected):
            invoke(f"{label}-generate", "generate", request(order), staged)
            if {path.name for path in output.iterdir()} != {SHARD, INDEX}:
                raise ValueError(f"{label}: configured generation must emit exactly the two declared Swift files")
            shard = (output / SHARD).read_bytes()
            emitted_ids = sorted(match.decode("utf-8") for match in ENDPOINT.findall(shard))
            reported_ids = sorted(endpoint["id"] for endpoint in expected)
            if emitted_ids != reported_ids:
                raise ValueError(f"{label}: inspected IDs differ from emitted EndpointID declarations: {emitted_ids!r}")
            cases[label]["shardSHA256"] = sha256(shard)

        original = expected_endpoints(root, configuration, parent)
        original_report = inspect("original", sources, original)
        require_generated_matches("original", sources, original)

        reversed_sources = list(reversed(sources))
        reordered_report = inspect("reordered", reversed_sources, original)
        if reordered_report != original_report:
            raise ValueError("Reversing the input file order changed the inspection bytes")

        whitespace = DIRECTORY_SOURCE.replace(
            "    func lookup(for key: String)", "\n        func   lookup( for key : String )",
        )
        if whitespace == DIRECTORY_SOURCE:
            raise ValueError("The whitespace fixture must modify the same protocol requirement in place")
        root.write_text(whitespace, encoding="utf-8")
        moved = expected_endpoints(root, configuration, parent, moved=True)
        inspect("whitespace", reversed_sources, moved)
        require_generated_matches("whitespace", reversed_sources, moved)
        if [entry["id"] for entry in moved] != [entry["id"] for entry in original]:
            raise ValueError("Whitespace changed the stable declaration IDs")

        asynchronous = whitespace.replace(" ) -> String", " ) async -> String")
        if asynchronous == whitespace:
            raise ValueError("The effect fixture must change only sync to async on the selected requirement")
        root.write_text(asynchronous, encoding="utf-8")
        changed = expected_endpoints(root, configuration, parent, moved=True, asynchronous=True)
        inspect("async-effect", sources, changed)
        require_generated_matches("async-effect", sources, changed)
        if changed[0]["id"] == moved[0]["id"] or changed[1] != moved[1]:
            raise ValueError("Changing the selected requirement's effect must change only its ID")
        if parent.read_text(encoding="utf-8") != PARENT_SOURCE:
            raise ValueError("Configured generation modified the authored inherited requirement")

    return {
        "status": "passed",
        "inputSetID": INPUT_SET,
        "generatorSHA256": sha256(tool.read_bytes()),
        "cases": cases,
        "checks": checks,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    tool = options.tool.absolute()
    if not tool.is_file() or not os.access(tool, os.X_OK):
        parser.error("--tool must point to an executable")
    evidence = options.evidence_dir.resolve()
    try:
        evidence.mkdir(parents=True, exist_ok=True)
        report_path = evidence / REPORT
        report_path.unlink(missing_ok=True)
        report = verify(tool, evidence)
        data = (json.dumps(report, indent=2) + "\n").encode()
        report_path.write_bytes(data)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Endpoint inspection verification failed: {error}", file=sys.stderr)
        return 1
    print(f"EVIDENCE: {REPORT} SHA-256 {sha256(data)}")
    print("PASS: SYS007 configured inspection reports stable and effect-sensitive endpoint IDs with declaration origins")
    return 0


if __name__ == "__main__":
    sys.exit(main())
