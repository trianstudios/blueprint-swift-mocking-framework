#!/usr/bin/env python3
"""Verify configured output preservation when escaping callback generation rejects a requirement."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from verify_inspection import OUTPUT_NAMES, require_unchanged, sha256, snapshot


MODULE = "ConsumerDomain"
PROTOCOL = "EscapingCallbackDirectory"
SUPPORTED = "func register(id: String, using callback: @escaping @Sendable (Int) -> String) -> String"
SHAPE_DIAGNOSTIC = (
    "Escaping callback capture requires one @escaping @Sendable synchronous nonthrowing function argument"
)
METHOD_DIAGNOSTIC = (
    "Escaping callback capture requires a synchronous nonthrowing Sendable method with one callback "
    "in the final position"
)
REJECTIONS = (
    ("bare-escaping", SUPPORTED.replace("@Sendable ", ""), SHAPE_DIAGNOSTIC),
    ("actor-isolated", SUPPORTED.replace("@Sendable ", "@MainActor @Sendable "), SHAPE_DIAGNOSTIC),
    ("effectful-callback", SUPPORTED.replace("(Int) ->", "(Int) async ->"), SHAPE_DIAGNOSTIC),
    (
        "non-final-callback",
        "func register(using callback: @escaping @Sendable (Int) -> String, id: String) -> String",
        METHOD_DIAGNOSTIC,
    ),
    (
        "effectful-method",
        "func register(id: String, using callback: @escaping @Sendable (Int) -> String) async -> String",
        METHOD_DIAGNOSTIC,
    ),
)
REPORT_NAME = "escaping-callback-generation-report.json"


def write_source(source, method):
    source.write_text(f"public protocol {PROTOCOL}: Sendable {{\n    {method}\n}}\n", encoding="utf-8")


def invoke(tool, request, evidence, label, checks):
    result = subprocess.run(
        [str(tool), *request], capture_output=True, timeout=30, check=False
    )
    artifacts = {}
    for stream, data in (("stdout", result.stdout), ("stderr", result.stderr)):
        artifact = evidence / f"escaping-callback-{label}.{stream}"
        artifact.write_bytes(data)
        artifacts[artifact.name] = sha256(data)
    checks[label] = {"exit": result.returncode, "artifacts": artifacts}
    return result


def require_rejection(result, location, diagnostic, label):
    if result.returncode != 1 or result.stdout or not re.search(
        location + rb"[^\n]*" + re.escape(diagnostic.encode("utf-8")), result.stderr
    ):
        actual = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"{label}: expected a source-located BPM001 (exit {result.returncode}): {actual}")


def verify(tool, evidence):
    checks = {}
    with tempfile.TemporaryDirectory(prefix="Configured Escaping Callback ", dir=evidence) as temporary:
        staged = Path(temporary)
        source = staged / f"{PROTOCOL}.swift"
        write_source(source, SUPPORTED)
        configuration = staged / "blueprint-mocking.json"
        selection = {"module": MODULE, "type": PROTOCOL, "kind": "protocol"}
        configuration.write_text(
            json.dumps({"schemaVersion": 1, "selections": [selection]}) + "\n", encoding="utf-8"
        )
        output = staged / "Generated Swift"
        request = [
            "generate", "--config", str(configuration), "--output", str(output), "--input-set-id", "a016",
            "--source", MODULE, str(source),
        ]
        generated = invoke(tool, request, evidence, "prepare", checks)
        if generated.returncode != 0 or generated.stderr:
            diagnostic = generated.stderr.decode("utf-8", errors="replace").strip()
            raise ValueError(f"prepare: supported configured generation exited {generated.returncode}: {diagnostic}")
        if {path.name for path in output.iterdir()} != set(OUTPUT_NAMES):
            raise ValueError("prepare: configured generation did not write the two owned Swift files")
        shard = (output / OUTPUT_NAMES[0]).read_text(encoding="utf-8")
        if f"class {PROTOCOL}Mock" not in shard:
            raise ValueError("prepare: the configured protocol mock is absent from the generated shard")
        print("PASS: GEN016 configured generation creates both owned outputs", flush=True)

        location = rb"(?m)^.*" + re.escape(source.name.encode("utf-8")) + rb":[1-9]\d*:[1-9]\d*: error: BPM001: "
        for label, method, diagnostic in REJECTIONS:
            write_source(source, method)
            before = snapshot(staged)
            rejected = invoke(tool, request, evidence, label, checks)
            require_unchanged(staged, before, label)
            require_rejection(rejected, location, diagnostic, label)
            print(f"PASS: GEN016 {label} rejected with both owned outputs preserved", flush=True)

        standalone = staged / "EscapingCallbackDirectoryMock.swift"
        standalone.write_bytes((output / OUTPUT_NAMES[0]).read_bytes())
        for label, method, option, selector, diagnostic in (
            ("callback-projection", SUPPORTED, "--project", "register(id:using:)", "cannot retain a callback requirement"),
            ("callback-forwarding", SUPPORTED.replace("id: String", "id: String..."), "--forward-variadic",
             "register(id:using:)", "cannot forward a callback requirement"),
        ):
            write_source(source, method)
            before = snapshot(staged)
            rejected = invoke(tool, [
                "--input", str(source), "--module", MODULE, "--protocol", PROTOCOL,
                "--output", str(standalone), option, selector,
            ], evidence, label, checks)
            require_unchanged(staged, before, label)
            require_rejection(rejected, location, diagnostic, label)
            print(f"PASS: GEN016 {label} rejected with standalone output preserved", flush=True)

    report = evidence / REPORT_NAME
    report.write_text(json.dumps({"checks": checks}, indent=2) + "\n", encoding="utf-8")
    print(f"EVIDENCE: {report.name} SHA-256 {sha256(report.read_bytes())}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    try:
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / REPORT_NAME).unlink(missing_ok=True)
        verify(options.tool.resolve(strict=True), evidence)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Escaping callback generation verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
