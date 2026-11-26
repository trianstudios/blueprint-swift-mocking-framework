#!/usr/bin/env python3
"""Exercise recovery of the two configured Swift generation outputs."""

import argparse
import base64
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
CHECKPOINT_FLAG = "BLUEPRINT_TEST_PUBLICATION_CHECKPOINT"
GENERATED = b"Blueprint Mocking: generated 1 protocol mock(s)\n"
VERIFIED = b"Blueprint Mocking: verified 2 generated file(s)\n"
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
    checkpoint_rows = {}
    environment = os.environ.copy()
    environment.pop(CHECKPOINT_FLAG, None)
    environment.pop("BLUEPRINT_TEST_ABORT_AFTER_SHARD", None)

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
        def request(input_set_id):
            return ["--config", config, "--output", output, "--input-set-id", input_set_id,
                    "--source", "OfflineDomain", authored]

        options = request("94")

        def run(label, arguments, *, checkpoint=None):
            authored_before = authored.read_bytes()
            child = subprocess.run(
                [str(part) for part in arguments], cwd=root,
                env=environment | ({CHECKPOINT_FLAG: checkpoint} if checkpoint else {}),
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

        def successful(label, verb, args=options):
            child = run(label, [tool, verb, *args])
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
            def observe():
                files = (shard, index, journal) if journal.exists() else (shard, index)
                return {file.name: (file.read_bytes(), file.stat().st_mtime_ns) for file in files}

            def expected_journal(next_pair):
                def encoded(contents):
                    return {"shard": base64.b64encode(contents[SHARD]).decode("ascii"),
                            "index": base64.b64encode(contents[INDEX]).decode("ascii")}
                return {"schema": 1, "previous": encoded(original), "next": encoded(next_pair)}

            def check_state(label, expected, pending):
                state = observe()
                if {name: state[name][0] for name in (SHARD, INDEX)} != expected:
                    raise ValueError(f"{label}: generated bytes do not match the expected checkpoint state")
                if JOURNAL in state:
                    if pending is None or json.loads(state[JOURNAL][0]) != expected_journal(pending):
                        raise ValueError(f"{label}: unexpected recovery journal")
                elif pending is not None:
                    raise ValueError(f"{label}: the recovery journal is missing")
                return state

            def reset_old(label):
                authored.write_bytes(original_source)
                successful(label, "generate")
                return check_state(label, original, None)

            def interrupt(label, checkpoint, args=options):
                child = run(label, [fault_tool, "generate", *args], checkpoint=checkpoint)
                diagnostic = f"DX013 fixture: interrupted at {checkpoint}\n".encode()
                require_result(label, child, exit_code=93, stderr=diagnostic)

            def exercise(label, checkpoint, expected, pending, target, *,
                         clean_source=None, input_set_id="94"):
                args = request(input_set_id)
                requested_source = authored.read_bytes()
                interrupt(f"interrupted-{label}", checkpoint, args)
                state = check_state(label, expected, pending)
                for name, (contents, _) in state.items():
                    artifact = f"generation-recovery-checkpoint-{label}-{name}"
                    retain(artifact, contents)
                    if label == "after-shard":
                        retain(f"generation-recovery-dirty-{name}", contents)

                if clean_source is not None:
                    authored.write_bytes(clean_source)
                if pending is None:
                    successful(f"verify-{label}", "verify-generated", args)
                else:
                    rejected = run(f"verify-{label}", [tool, "verify-generated", *args])
                    require_result(f"verify-{label}", rejected, exit_code=1, stderr=DIRTY_DIAGNOSTIC)
                if observe() != state:
                    raise ValueError(f"{label}: verify-generated changed the checkpoint state")

                if swiftc is not None and expected[INDEX] == DIRTY_INDEX:
                    compiler = [swiftc, "-swift-version", "6", "-typecheck"]
                    if sdk is not None:
                        compiler.extend(["-sdk", sdk])
                    rejected = run(f"typecheck-{label}", [*compiler, index])
                    if rejected.returncode == 0 or b"error: " + DIRTY_MESSAGE not in rejected.stderr:
                        raise ValueError(f"{label}: the compiler missed the actual dirty index's Swift #error")
                    print(f"PASS: generation recovery typecheck-{label}", flush=True)
                    if observe() != state:
                        raise ValueError(f"{label}: type checking changed the checkpoint state")

                authored.write_bytes(requested_source)
                successful(f"retry-{label}", "generate", args)
                recovered = check_state(label, target, None)
                if expected == target and any(recovered[name] != state[name] for name in (SHARD, INDEX)):
                    raise ValueError(f"{label}: recovery rewrote an already complete valid output")
                successful(f"verify-retry-{label}", "verify-generated", args)
                successful(f"repeat-{label}", "generate", args)
                if observe() != recovered:
                    raise ValueError(f"{label}: an unchanged repeat rewrote generated output")

                checkpoint_rows[label] = {
                    "checkpoint": checkpoint,
                    "inputSetID": input_set_id,
                    "journal": JOURNAL in state,
                    "observedOutputs": {
                        name: {"sha256": digest(contents), "mtimeNs": mtime}
                        for name, (contents, mtime) in state.items() if name != JOURNAL
                    },
                    "retryPreservedCompleteOutput": expected == target,
                    "unchangedRepeat": True,
                }
                return recovered

            dirty_old = original | {INDEX: DIRTY_INDEX}
            dirty_new = new | {INDEX: DIRTY_INDEX}
            forward = (
                ("before-journal", original, None),
                ("after-journal", original, new),
                ("after-dirty-index", dirty_old, new),
                ("after-shard", dirty_new, new),
                ("after-index", new, new),
                ("after-journal-removal", new, None),
            )
            for checkpoint, expected, pending in forward:
                reset_old(f"setup-{checkpoint}")
                authored.write_bytes(next_source)
                exercise(checkpoint, checkpoint, expected, pending, new,
                         clean_source=original_source if checkpoint == "before-journal" else None)

            recovery = (
                ("recovery-after-shard", dirty_old, new),
                ("recovery-after-index", original, new),
                ("recovery-after-journal-removal", original, None),
            )
            for checkpoint, expected, pending in recovery:
                reset_old(f"setup-{checkpoint}")
                authored.write_bytes(next_source)
                interrupt(f"seed-{checkpoint}", "after-shard")
                check_state(f"seed-{checkpoint}", dirty_new, new)
                authored.write_bytes(original_source)
                exercise(checkpoint, checkpoint, expected, pending, original)

            reset_old("setup-index-only")
            successful("prepare-index-only", "generate", request("95"))
            index_only = pair(output)
            if index_only[SHARD] != original[SHARD] or index_only[INDEX] == original[INDEX]:
                raise ValueError("Changing only input-set ID must update only the index")
            old_index_state = reset_old("reset-index-only")
            recovered = exercise("index-only-after-index", "after-index", index_only, index_only, index_only,
                                 input_set_id="95")
            if recovered[SHARD] != old_index_state[SHARD]:
                raise ValueError("Index-only recovery rewrote the unchanged shard")

    return {
        "inputSetID": "94",
        "faultInjection": fault_tool is not None,
        "dirtySwiftTypechecked": swiftc is not None,
        "checkpoints": checkpoint_rows,
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
