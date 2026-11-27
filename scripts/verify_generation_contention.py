#!/usr/bin/env python3
"""Verify serialization of configured publishers and read-only inspection during publication."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time

from verify_generation_recovery import (
    CHECKPOINT_FLAG, DIRTY_DIAGNOSTIC, DIRTY_INDEX, FIXTURE, GENERATED, INDEX, JOURNAL,
    SHARD, VERIFIED, digest, pair,
)
from verify_inspection import snapshot


PAUSE = "BLUEPRINT_TEST_PUBLICATION_PAUSE_AT"
OBSERVE_LOCK = "BLUEPRINT_TEST_OBSERVE_OUTPUT_LOCK"
CONTENDED = b"DX013 fixture: output lock contended\n"
TIMEOUT = 15


def pause_event(checkpoint):
    return f"DX013 fixture: paused at {checkpoint}\n".encode()


def require_result(label, exit_code, stdout, stderr, *, expected_exit=0, expected_stdout=b"", expected_stderr=b""):
    if (exit_code, stdout, stderr) != (expected_exit, expected_stdout, expected_stderr):
        raise ValueError(f"{label}: unexpected status or output (exit {exit_code}), see its raw logs")


class PausedWriter:
    def __init__(self, child, reader, stdout):
        self.child = child
        self.reader = reader
        self.stdout = stdout
        self.stderr = bytearray()
        self.checked = 0
        reader.register(child.stderr, selectors.EVENT_READ)

    def collect(self, timeout):
        for key, _ in self.reader.select(timeout):
            data = os.read(key.fd, 65536)
            if data:
                self.stderr.extend(data)
            else:
                self.reader.unregister(key.fileobj)

    def expect_event(self, expected):
        deadline = time.monotonic() + TIMEOUT
        end = self.stderr.find(b"\n", self.checked)
        while end < 0 and self.reader.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            self.collect(remaining)
            end = self.stderr.find(b"\n", self.checked)
        if end < 0:
            raise ValueError(f"Writer did not emit expected event {expected.decode().strip()!r}")
        actual = self.stderr[self.checked:end + 1]
        if actual != expected:
            raise ValueError(f"Expected writer event {expected!r} but got {actual!r}")
        self.checked = end + 1

    def require_waiting(self):
        self.collect(0)
        if self.child.poll() is not None or len(self.stderr) != self.checked or self.stdout.stat().st_size:
            raise ValueError("A writer continued before its publication barrier was released")

    def resume(self):
        self.child.stdin.write(b"\n")
        self.child.stdin.close()

    def finish(self):
        deadline = time.monotonic() + TIMEOUT
        while self.reader.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Timed out waiting for writer output pipes to close")
            self.collect(remaining)
        exit_code = self.child.wait(timeout=max(0, deadline - time.monotonic()))
        return exit_code, self.stdout.read_bytes(), bytes(self.stderr)


def verify(repository, tool, fault, evidence):
    checks = {}
    stages = {}
    environment = os.environ.copy()
    for flag in (PAUSE, OBSERVE_LOCK, CHECKPOINT_FLAG, "BLUEPRINT_TEST_ABORT_AFTER_SHARD"):
        environment.pop(flag, None)

    with tempfile.TemporaryDirectory(prefix="Configured Writer Contention ", dir=evidence) as temporary:
        root = Path(temporary)
        fixture = repository / FIXTURE
        source = root / "Lookup.swift"
        alternate_header = b"public protocol RevisionLookup: Sendable {"
        source_bytes = (fixture / "Sources/OfflineDomain/Lookup.swift").read_bytes() + (
            b"\n" + alternate_header + b"\n    func value(for key: String) -> Int\n}\n"
        )
        source.write_bytes(source_bytes)
        original_configuration = json.loads((fixture / "blueprint-mocking.json").read_bytes())
        selected_a, = original_configuration["selections"]
        selected_b = selected_a | {"type": "RevisionLookup"}
        config_a, config_b = (root / name for name in ("Writer A.json", "Writer B.json"))
        config_a.write_bytes((fixture / "blueprint-mocking.json").read_bytes())
        config_b.write_text(json.dumps(original_configuration | {"selections": [selected_b]}) + "\n")
        authored = {path: path.read_bytes() for path in (source, config_a, config_b)}
        shared = root / "Shared Output"
        shared.mkdir()

        def request(config, destination, input_set_id):
            return ["--config", str(config), "--output", str(destination), "--input-set-id", input_set_id,
                    "--source", "OfflineDomain", str(source)]

        request_a = request(config_a, shared, "97")
        request_b = request(config_b, shared, "98")

        def log_path(label, stream):
            return evidence / f"generation-contention-{label}.{stream}"

        def record(label, exit_code, stdout, stderr):
            artifacts = {}
            for stream, data in (("stdout", stdout), ("stderr", stderr)):
                log = log_path(label, stream)
                log.write_bytes(data)
                artifacts[log.name] = digest(data)
            checks[label] = {"exit": exit_code, "artifacts": artifacts}
            if any(path.read_bytes() != data for path, data in authored.items()):
                raise ValueError(f"{label}: authored inputs changed")

        def run(label, verb, options, *, extra=None):
            child = subprocess.run(
                [str(tool), verb, *options], cwd=root, env=environment | (extra or {}),
                stdin=subprocess.DEVNULL, capture_output=True, timeout=TIMEOUT, check=False,
            )
            outcome = child.returncode, child.stdout, child.stderr
            record(label, *outcome)
            return outcome

        @contextmanager
        def writer(label, options, checkpoint, *, observe_lock=False):
            extra = {PAUSE: checkpoint}
            if observe_lock:
                extra[OBSERVE_LOCK] = "1"
            stdout = log_path(label, "stdout")
            with stdout.open("wb") as output, selectors.DefaultSelector() as reader:
                child = subprocess.Popen(
                    [str(fault), "generate", *options], cwd=root, env=environment | extra,
                    stdin=subprocess.PIPE, stdout=output, stderr=subprocess.PIPE, bufsize=0,
                )
                running = PausedWriter(child, reader, stdout)
                try:
                    yield running
                finally:
                    if child.poll() is None:
                        child.kill()
                    try:
                        record(label, *running.finish())
                    finally:
                        child.stdin.close()
                        child.stderr.close()

        expected_a = root / "Expected A"
        expected_b = root / "Expected B"
        require_result("expected-a", *run("expected-a", "generate", request(config_a, expected_a, "97")),
                       expected_stdout=GENERATED)
        control = run("expected-b-production-control", "generate", request(config_b, expected_b, "98"),
                      extra={PAUSE: "before-journal", OBSERVE_LOCK: "1"})
        require_result("expected-b-production-control", *control, expected_stdout=GENERATED)
        version_a, version_b = pair(expected_a), pair(expected_b)
        if any(version_a[name] == version_b[name] for name in (SHARD, INDEX)):
            raise ValueError("The independent configurations must produce different shards and indexes")

        def require_pair(expected):
            if set(path.name for path in shared.iterdir()) != {SHARD, INDEX} or pair(shared) != expected:
                raise ValueError("The shared folder did not contain exactly the expected complete pair")

        def dirty_state():
            if (set(path.name for path in shared.iterdir()) != {SHARD, INDEX, JOURNAL}
                    or pair(shared) != {SHARD: version_a[SHARD], INDEX: DIRTY_INDEX}
                    or not (shared / JOURNAL).read_bytes()):
                raise ValueError("Expected the A shard, dirty index, and a retained journal")
            return snapshot(shared)

        def inspect_b(label, expected_state):
            exit_code, stdout, stderr = run(label, "inspect", [*request_b, "--format", "json"])
            if exit_code or stderr:
                raise ValueError(f"{label}: inspect failed with exit {exit_code}")
            parsed = json.loads(stdout)
            expected = {
                "schemaVersion": 1,
                "configuration": original_configuration | {"selections": [selected_b]},
                "inputSetID": "98",
                "inputs": {
                    "configuration": config_b.name,
                    "sources": [{"module": "OfflineDomain", "path": source.name}],
                },
                "declarations": [selected_b | {
                    "file": source.name,
                    "line": source_bytes.splitlines().index(alternate_header) + 1,
                    "generatedType": "RevisionLookupMock",
                    "endpoints": [{
                        "id": "schema1|OfflineDomain.RevisionLookup|value(for:String)->Int|Sendable",
                        "module": "OfflineDomain",
                        "file": source.name,
                        "line": source_bytes.splitlines().index(b"    func value(for key: String) -> Int") + 1,
                        "column": 5,
                    }],
                }],
                "outputOwnership": {
                    "owner": "BlueprintMockingBuildPlugin",
                    "files": [str((shared / name).relative_to(root)) for name in (SHARD, INDEX)],
                },
            }
            if any(parsed.get(key) != value for key, value in expected.items()):
                raise ValueError(f"{label}: inspection did not return the expected B declaration and output ownership")
            if snapshot(shared) != expected_state:
                raise ValueError(f"{label}: inspection changed output bytes or metadata")
            return stdout

        with writer("serial-writer-a", request_a, "after-shard") as a:
            a.expect_event(pause_event("after-shard"))
            serial_dirty = dirty_state()
            stages["serialDirty"] = serial_dirty
            with writer("serial-writer-b", request_b, "before-journal", observe_lock=True) as b:
                b.expect_event(CONTENDED)
                inspected = inspect_b("inspect-while-writers-contend", serial_dirty)
                a.require_waiting()
                b.require_waiting()

                a.resume()
                require_result("serial-writer-a", *a.finish(),
                               expected_stdout=GENERATED, expected_stderr=pause_event("after-shard"))
                b.expect_event(pause_event("before-journal"))
                b.require_waiting()
                require_pair(version_a)
                stages["serialA"] = snapshot(shared)

                b.resume()
                require_result("serial-writer-b", *b.finish(),
                               expected_stdout=GENERATED, expected_stderr=CONTENDED + pause_event("before-journal"))
                require_pair(version_b)
                stages["serialB"] = snapshot(shared)

        require_result("verify-serial-b", *run("verify-serial-b", "verify-generated", request_b),
                       expected_stdout=VERIFIED)
        if snapshot(shared) != stages["serialB"]:
            raise ValueError("Verifying the serialized B output changed it")
        if inspect_b("inspect-before-interruption", stages["serialB"]) != inspected:
            raise ValueError("B inspection depended on the previously published state")

        with writer("interrupted-writer-a", request_a, "after-shard") as interrupted:
            interrupted.expect_event(pause_event("after-shard"))
            interrupted_state = dirty_state()
            stages["interrupted"] = interrupted_state
            if inspect_b("inspect-before-writer-termination", interrupted_state) != inspected:
                raise ValueError("B inspection depended on the active writer")
            interrupted.require_waiting()
            interrupted.child.kill()
            require_result("interrupted-writer-a", *interrupted.finish(),
                           expected_exit=-signal.SIGKILL, expected_stderr=pause_event("after-shard"))

        if inspect_b("inspect-after-writer-termination", interrupted_state) != inspected:
            raise ValueError("B inspection depended on whether the interrupted writer was alive")
        require_result("verify-interrupted", *run("verify-interrupted", "verify-generated", request_b),
                       expected_exit=1, expected_stderr=DIRTY_DIAGNOSTIC)
        if snapshot(shared) != interrupted_state:
            raise ValueError("Verifying interrupted output changed its bytes or metadata")

        require_result("recover-b", *run("recover-b", "generate", request_b), expected_stdout=GENERATED)
        require_pair(version_b)
        stages["recovered"] = snapshot(shared)
        require_result("verify-recovered-b", *run("verify-recovered-b", "verify-generated", request_b),
                       expected_stdout=VERIFIED)
        if snapshot(shared) != stages["recovered"]:
            raise ValueError("Verifying recovered output changed it")
        require_result("repeat-recovered-b", *run("repeat-recovered-b", "generate", request_b),
                       expected_stdout=GENERATED)
        if snapshot(shared) != stages["recovered"]:
            raise ValueError("An unchanged generation rewrote recovered output")

    return {
        "checks": checks,
        "expectedPairs": {
            label: {name: digest(contents) for name, contents in version.items()}
            for label, version in (("A", version_a), ("B", version_b))
        },
        "stages": stages,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--fault-tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()

    try:
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        report = evidence / "generation-contention-report.json"
        report.unlink(missing_ok=True)
        repository = Path(__file__).resolve().parents[1]
        tool, fault = (path.resolve(strict=True) for path in (options.tool, options.fault_tool))
        if tool == fault:
            raise ValueError("Use distinct production and fault-instrumented generators")
        results = verify(repository, tool, fault, evidence)
        report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Generation contention verification failed: {error}", file=sys.stderr)
        return 1
    print(f"EVIDENCE: {report.name} SHA-256 {digest(report.read_bytes())}")
    print("PASS: DX013 configured writers serialized and inspection preserved interrupted output")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
