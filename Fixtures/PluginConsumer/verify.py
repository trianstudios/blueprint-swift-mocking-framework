#!/usr/bin/env python3
"""Verify build-tool graph invalidation in a fresh SwiftPM plugin consumer."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


FIXTURE = Path("Fixtures/PluginConsumer")
CONFIGURATION = "blueprint-mocking.json"
MOCKS = "BlueprintMocks.generated.swift"
INDEX = "BlueprintMockingIndex.generated.swift"
EXPECTED_OUTPUTS = {MOCKS, INDEX}
GENERATION_STAMP = "Blueprint Mocking: generated"
PROBE_PASS = "PASS: DX004 plugin-generated mock compiled and ran"
SWIFT_SYNTAX_VERSION = "600.0.1"
SWIFT_SYNTAX_REVISION = "0687f71944021d616d34d922343dcef086855920"
SWIFT_INPUTS = (
    Path("Package.swift"),
    Path("Sources"),
    Path("Packages/Tooling"),
    FIXTURE,
)


def stage_checkout(source, checkout):
    ignore = shutil.ignore_patterns(".build", ".swiftpm", ".git", "__pycache__")
    for relative in SWIFT_INPUTS:
        original = source / relative
        destination = checkout / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if original.is_dir():
            shutil.copytree(original, destination, ignore=ignore, symlinks=True)
        else:
            shutil.copy2(original, destination)


def swift_files(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*.swift")}


def resolved_syntax(fixture):
    manifest = json.loads((fixture / "Package.resolved").read_text(encoding="utf-8"))
    pins = [pin for pin in manifest["pins"] if pin["identity"] == "swift-syntax"]
    expected = {
        "identity": "swift-syntax",
        "kind": "remoteSourceControl",
        "location": "https://github.com/swiftlang/swift-syntax.git",
        "state": {"version": SWIFT_SYNTAX_VERSION, "revision": SWIFT_SYNTAX_REVISION},
    }
    if pins != [expected]:
        raise ValueError(f"Unexpected resolved SwiftSyntax pin: {pins}")
    return pins[0]


def output_state(build, checkout):
    located = {}
    for path in build.rglob("Blueprint*.generated.swift"):
        if path.name in located or not path.resolve().is_relative_to(build.resolve()):
            raise ValueError(f"Unexpected generated Swift output location {path}")
        contents = path.read_bytes()
        if str(checkout).encode() in contents:
            raise ValueError(f"Local checkout path leaked into {path.name}")
        located[path.name] = {
            "sha256": hashlib.sha256(contents).hexdigest(),
            "mtimeNs": path.stat().st_mtime_ns,
            "path": str(path.relative_to(build)),
        }
    if set(located) != EXPECTED_OUTPUTS:
        raise ValueError(f"Expected only the declared Swift outputs, got {sorted(located)}")
    return located


def marker_line(source):
    lines = [number for number, line in enumerate(source.splitlines(), 1)
             if line == "    func mark(_ key: String)"]
    if len(lines) != 1:
        raise ValueError("The probe declaration must contain exactly one mark requirement")
    return lines[0]


def run_probe(command, fixture, evidence, step, *, origin=None, stamp=None, failure=None):
    log = evidence / f"swiftpm-plugin-{step}.log"
    source_before = swift_files(fixture / "Sources")
    configuration = fixture / CONFIGURATION
    configuration_before = configuration.read_bytes()
    manifest = fixture / "Package.swift"
    manifest_before = manifest.read_bytes()
    with log.open("wb") as capture:
        result = subprocess.run(command, cwd=fixture, stdout=capture,
                                stderr=subprocess.STDOUT, timeout=600, check=False)
    log_bytes = log.read_bytes()
    output = log_bytes.decode("utf-8", errors="replace")
    if (source_before != swift_files(fixture / "Sources") or configuration.read_bytes() != configuration_before
            or manifest.read_bytes() != manifest_before):
        raise ValueError(f"{step}: the build changed authored inputs")
    if failure is None:
        if result.returncode != 0 or output.count(PROBE_PASS) != 1 or output.splitlines().count(origin) != 1:
            raise ValueError(f"{step}: the generated probe did not report {origin}; see {log}")
        if stamp is not None and (GENERATION_STAMP in output) != stamp:
            raise ValueError(f"{step}: unexpected generator execution; see {log}")
    elif (result.returncode == 0 or PROBE_PASS in output or GENERATION_STAMP in output
          or not re.search(failure, output, re.IGNORECASE)):
        raise ValueError(f"{step}: expected a generator diagnostic without a runnable stale mock; see {log}")
    print(f"PASS: SwiftPM plugin {step}", flush=True)
    return {"exit": result.returncode, "log": log.name, "logSHA256": hashlib.sha256(log_bytes).hexdigest()}


def verify(source, swift, evidence, cache, jobs):
    with tempfile.TemporaryDirectory(prefix="Fresh SwiftPM Plugin Checkout ", dir=evidence) as directory:
        checkout = Path(directory)
        stage_checkout(source, checkout)
        fixture = checkout / FIXTURE
        build = checkout / "SwiftPM Build Outputs"
        command = [str(swift), "run", "--package-path", str(fixture), "--scratch-path", str(build),
                   "--jobs", str(jobs)]
        if cache is not None:
            command += ["--cache-path", str(cache)]
        command += ["PluginProbe"]
        inputs = fixture / "Sources/PluginDomain"
        lookup = inputs / "Lookup.swift"
        original = lookup.read_text(encoding="utf-8")
        reports = {}

        def run(step, filename, content, *, stamp=True, failure=None):
            origin = None if failure else (
                f"BLUEPRINT_PLUGIN_ORIGIN PluginDomain/{filename}|{filename}|{marker_line(content)}|1"
            )
            record = run_probe(command, fixture, evidence, step, origin=origin, stamp=stamp, failure=failure)
            outputs = output_state(build, checkout)
            record["outputs"] = outputs
            reports[step] = record
            return outputs

        baseline = run("clean", lookup.name, original)
        pin = resolved_syntax(fixture)
        repeated = run("unchanged", lookup.name, original, stamp=False)
        if repeated != baseline:
            raise ValueError("An unchanged SwiftPM build rewrote or moved generated Swift files")

        edited = "// Source location moved without changing the consumer.\n\n" + original
        lookup.write_text(edited, encoding="utf-8")
        edited_state = run("edit", lookup.name, edited)
        if edited_state[MOCKS]["sha256"] == baseline[MOCKS]["sha256"]:
            raise ValueError("The selected source edit did not change the generated mock")

        support = inputs / "New Supporting File.swift"
        support.write_text("enum NewlyTrackedDeclaration {}\n", encoding="utf-8")
        added = run("add", lookup.name, edited)
        if added[INDEX]["sha256"] == edited_state[INDEX]["sha256"] or added[MOCKS] != edited_state[MOCKS]:
            raise ValueError("A membership addition must invalidate the index and preserve the unchanged mock")
        support.unlink()
        removed = run("delete", lookup.name, edited)
        if removed[INDEX]["sha256"] != edited_state[INDEX]["sha256"] or removed[MOCKS] != edited_state[MOCKS]:
            raise ValueError("Membership removal did not restore the original index without rewriting the mock")

        renamed = inputs / "Renamed Lookup.swift"
        lookup.rename(renamed)
        renamed_state = run("rename", renamed.name, edited)
        if renamed_state[MOCKS]["sha256"] == edited_state[MOCKS]["sha256"]:
            raise ValueError("Renamed declaration did not alter generated source provenance")

        unsupported = edited.replace(
            "    func mark(_ key: String)\n",
            "    func mark(_ key: String)\n    func unsupported<T: Sendable>(_ input: T)\n",
        )
        renamed.write_text(unsupported, encoding="utf-8")
        rejected = run("unsupported", renamed.name, unsupported, failure=r"BPM001[^\n]*non-generic")
        if rejected != renamed_state:
            raise ValueError("An unsupported declaration rewrote or removed the last valid outputs")

        renamed.write_text(edited, encoding="utf-8")
        restored = run("recover", renamed.name, edited, stamp=None)
        if restored != renamed_state:
            raise ValueError("Restoring valid source changed stable generated outputs")

        renamed.unlink()
        missing = run("missing-selection", renamed.name, "", failure=r"BPM001[^\n]*Lookup")
        if missing != renamed_state:
            raise ValueError("A missing selected protocol rewrote or removed the last valid outputs")
        renamed.write_text(edited, encoding="utf-8")
        recovered = run("recover-selection", renamed.name, edited, stamp=None)
        if recovered != renamed_state:
            raise ValueError("Restoring the selected declaration changed stable generated outputs")

        configuration = fixture / CONFIGURATION
        valid_request = configuration.read_bytes()
        unknown_key = json.loads(valid_request) | {"unknownKey": True}
        configuration.write_text(json.dumps(unknown_key) + "\n", encoding="utf-8")
        invalid_config = run(
            "unknown-config-key", renamed.name, edited,
            failure=r"BPM002[^\n]*Expected schemaVersion and selections",
        )
        if invalid_config != renamed_state:
            raise ValueError("An unknown configuration key changed the last valid outputs")
        configuration.write_bytes(valid_request)
        restored_config = run("recover-config", renamed.name, edited, stamp=None)
        if restored_config != renamed_state:
            raise ValueError("Restoring configuration changed stable generated outputs")
        return {"swiftSyntaxPin": pin, "checks": reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--cache-path", type=Path, help="Shared SwiftPM dependency cache")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    options = parser.parse_args()
    evidence = options.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    cache = options.cache_path.resolve() if options.cache_path else None
    report = evidence / "swiftpm-plugin-report.json"
    report.unlink(missing_ok=True)
    reports = verify(options.source_root.resolve(), options.swift.absolute(), evidence, cache, options.jobs)
    report.write_text(json.dumps(reports, indent=2) + "\n", encoding="utf-8")
    digest = hashlib.sha256(report.read_bytes()).hexdigest()
    print(f"EVIDENCE: {report.name} SHA-256 {digest}")
    print("PASS: DX004 SwiftPM plugin clean build, regeneration, and incremental stability")


if __name__ == "__main__":
    main()
