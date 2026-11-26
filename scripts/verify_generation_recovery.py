#!/usr/bin/env python3
"""Exercise recovery of the two configured Swift generation outputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


FIXTURE = Path("Fixtures/OfflineGenerationConsumer")
SHARD = "BlueprintMocks.generated.swift"
INDEX = "BlueprintMockingIndex.generated.swift"
JOURNAL = ".blueprint-mocking-transaction.json"
FAULT_FLAG = "BLUEPRINT_TEST_ABORT_AFTER_SHARD"
GENERATED = b"Blueprint Mocking: generated 1 protocol mock(s)\n"
VERIFIED = b"Blueprint Mocking: verified 2 generated file(s)\n"
FAULT_DIAGNOSTIC = b"DX013 fixture: interrupted after shard publication\n"
DIRTY_MESSAGE = b"Blueprint Mocking: interrupted output publication. Rerun generation to recover."
DIRTY_INDEX = b'#error("' + DIRTY_MESSAGE + b'")\n'
DIRTY_DIAGNOSTIC = b"error: BPM004: Interrupted generated output publication. Rerun generation to recover.\n"


def digest(contents):
    return hashlib.sha256(contents).hexdigest()


def pair(output):
    snapshots = {name: (output / name).read_bytes() for name in (SHARD, INDEX)}
    if not all(snapshots.values()):
        raise ValueError("Both generated Swift files must be nonempty")
    return snapshots


def verify(repository, tool, evidence, *, fault_tool=None, swiftc=None, sdk=None):
    records = {}
    artifacts = {}
    environment = os.environ.copy()
    environment.pop(FAULT_FLAG, None)

    def retain(name, contents):
        (evidence / name).write_bytes(contents)
        artifacts[name] = digest(contents)

    with tempfile.TemporaryDirectory(prefix="Configured Output Recovery ", dir=evidence) as temporary:
        root = Path(temporary)
        authored = root / "Lookup.swift"
        original_source = (
            repository / FIXTURE / "Sources/OfflineDomain/Lookup.swift"
        ).read_bytes()
        closing = b"}\n"
        if original_source.count(closing) != 1:
            raise ValueError("The source fixture must have one protocol body")
        next_source = original_source.replace(closing, b"    func mark(_ key: String)\n}\n", 1)
        authored.write_bytes(original_source)
        config = root / "blueprint-mocking.json"
        configuration = (repository / FIXTURE / config.name).read_bytes()
        config.write_bytes(configuration)
        output = root / "Generated Swift"
        shard, index, journal = (output / name for name in (SHARD, INDEX, JOURNAL))
        options = ["--config", config, "--output", output, "--input-set-id", "94",
                   "--source", "OfflineDomain", authored]

        def run(label, arguments, *, fault=False):
            authored_before = authored.read_bytes()
            child = subprocess.run(
                [str(part) for part in arguments], cwd=root,
                env=environment | ({FAULT_FLAG: "1"} if fault else {}),
                capture_output=True, timeout=60, check=False,
            )
            logs = {}
            for name, data in (("stdout", child.stdout), ("stderr", child.stderr)):
                log = f"generation-recovery-{label}.{name}"
                retain(log, data)
                logs[name] = log
            records[label] = {"exit": child.returncode, **logs}
            if authored.read_bytes() != authored_before or config.read_bytes() != configuration:
                raise ValueError(f"{label}: the tool rewrote authored inputs")
            return child

        def require_result(label, child, *, exit_code, stdout=b"", stderr=b""):
            if (child.returncode, child.stdout, child.stderr) != (exit_code, stdout, stderr):
                raise ValueError(f"{label}: unexpected tool outcome, see generation-recovery-{label} logs")
            print(f"PASS: generation recovery {label}", flush=True)

        def successful(label, verb):
            child = run(label, [tool, verb, *options])
            require_result(label, child, exit_code=0, stdout=GENERATED if verb == "generate" else VERIFIED)

        successful("baseline", "generate")
        original = pair(output)
        for name, contents in original.items():
            retain(f"generation-recovery-old-{name}", contents)

        index.unlink()
        index.mkdir()
        authored.write_bytes(next_source)
        failed = run("blocked-index", [tool, "generate", *options])
        if failed.returncode == 0 or b"Blueprint Mocking: generated" in failed.stdout + failed.stderr:
            raise ValueError("blocked-index: generation reported success with a directory at the index path")
        if shard.read_bytes() != original[SHARD] or not index.is_dir() or list(index.iterdir()):
            raise ValueError("blocked-index: failed generation did not preserve the old shard and index directory")
        if journal.exists():
            raise ValueError("blocked-index: an invalid output path left a recovery journal")
        print("PASS: generation recovery blocked-index", flush=True)

        index.rmdir()
        index.write_bytes(original[INDEX])
        successful("retry-after-block", "generate")
        new = pair(output)
        if any(new[name] == original[name] for name in (SHARD, INDEX)):
            raise ValueError("The edited declaration must publish a different shard and index")
        successful("verify-retried-pair", "verify-generated")
        for name, contents in new.items():
            retain(f"generation-recovery-new-{name}", contents)

        if fault_tool is not None:
            authored.write_bytes(original_source)
            successful("setup-interruption", "generate")
            if pair(output) != original or journal.exists():
                raise ValueError("The interruption fixture did not restore the exact original pair")

            authored.write_bytes(next_source)
            interrupted = run("interrupted-after-shard", [fault_tool, "generate", *options], fault=True)
            require_result("interrupted-after-shard", interrupted, exit_code=93, stderr=FAULT_DIAGNOSTIC)
            if pair(output) != {SHARD: new[SHARD], INDEX: DIRTY_INDEX} or not journal.is_file():
                raise ValueError("The interrupted write did not leave the new shard, dirty index and recovery journal")
            dirty_files = (shard, index, journal)
            dirty_state = [(file.read_bytes(), file.stat().st_mtime_ns) for file in dirty_files]
            if not dirty_state[-1][0]:
                raise ValueError("The interrupted write left an empty recovery journal")
            for file, (contents, _) in zip(dirty_files, dirty_state, strict=True):
                retain(f"generation-recovery-dirty-{file.name}", contents)

            rejected = run("verify-dirty", [tool, "verify-generated", *options])
            require_result("verify-dirty", rejected, exit_code=1, stderr=DIRTY_DIAGNOSTIC)
            if [(file.read_bytes(), file.stat().st_mtime_ns) for file in dirty_files] != dirty_state:
                raise ValueError("verify-generated changed interrupted output")

            if swiftc is not None:
                compiler = [swiftc, "-swift-version", "6", "-typecheck"]
                if sdk is not None:
                    compiler.extend(["-sdk", sdk])
                rejected = run("typecheck-dirty-index", [*compiler, index])
                if rejected.returncode == 0 or b"error: " + DIRTY_MESSAGE not in rejected.stderr:
                    raise ValueError("The compiler did not diagnose the dirty index's explicit Swift #error")
                print("PASS: generation recovery typecheck-dirty-index", flush=True)

            authored.write_bytes(original_source)
            successful("restore-after-interruption", "generate")
            if pair(output) != original or journal.exists():
                raise ValueError("Recovery did not restore the exact original pair or clear the journal")
            successful("verify-restored", "verify-generated")

            authored.write_bytes(next_source)
            successful("publish-after-recovery", "generate")
            if pair(output) != new or journal.exists():
                raise ValueError("Generation after recovery did not publish the expected complete pair")
            successful("verify-final", "verify-generated")

    return {
        "inputSetID": "94",
        "faultInjection": fault_tool is not None,
        "dirtySwiftTypechecked": swiftc is not None,
        "checks": records,
        "artifacts": artifacts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--fault-tool", type=Path)
    parser.add_argument("--swiftc", type=Path)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    if options.swiftc is not None and options.fault_tool is None:
        parser.error("--swiftc requires --fault-tool")
    if options.sdk is not None and options.swiftc is None:
        parser.error("--sdk requires --swiftc")

    repository = Path(__file__).resolve().parents[1]
    try:
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        report = evidence / "generation-recovery-report.json"
        report.unlink(missing_ok=True)
        tool = options.tool.resolve(strict=True)
        fault = options.fault_tool.resolve(strict=True) if options.fault_tool is not None else None
        if fault == tool:
            raise ValueError("Use distinct production and fault-instrumented generator binaries")
        result = verify(repository, tool, evidence, fault_tool=fault, swiftc=options.swiftc, sdk=options.sdk)
        report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Generation recovery verification failed: {error}", file=sys.stderr)
        return 1
    print(f"EVIDENCE: {report.name} SHA-256 {digest(report.read_bytes())}")
    print("PASS: DX013 configured output generation preserves and recovers complete pairs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
