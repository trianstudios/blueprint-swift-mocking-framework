"""Check one pinned Swift Testing v0 fixture against its generated witness and inspection."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

from verify_closed_owner import native_test_command


TEST = "DX023_lateTypeScopeTaskKeepsOwningReporter()"
MODULE = "ConsumerDomain"
PROTOCOL = "TypeSubscriptDirectory"
SETTER = f"schema1|{MODULE}.{PROTOCOL}|type:subscript:(_:Int).set(_:Int,newValue:Int)->Void|Sendable"
MAX_BYTES = 64 * 1024
MAX_RECORD = 16 * 1024


class TransportError(ValueError):
    """The local fixture did not produce a complete, verifiable result."""


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise TransportError(f"duplicate key {key!r}")
        result[key] = value
    return result


def invalid_constant(token):
    raise TransportError(f"invalid JSON constant {token}")


def decode_json(raw, label):
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_keys, parse_constant=invalid_constant)
    except (ValueError, RecursionError) as error:
        raise TransportError(f"invalid JSON in {label}: {error}") from error


def native_records(raw):
    if len(raw) > MAX_BYTES:
        raise TransportError("native stream exceeds its byte limit")
    if not raw.endswith(b"\n"):
        raise TransportError("incomplete native stream without a terminal newline")
    records = []
    for number, line in enumerate(raw[:-1].split(b"\n"), 1):
        if len(line) > MAX_RECORD:
            raise TransportError(f"native record {number} exceeds its byte limit")
        record = decode_json(line, f"native record {number}")
        if not isinstance(record, dict) or type(record.get("version")) is not int or record["version"] != 0:
            raise TransportError(f"expected native event version 0 in record {number}")
        payload = record.get("payload")
        if record.get("kind") not in ("test", "event") or not isinstance(payload, dict):
            raise TransportError(f"malformed native record {number}")
        records.append((record["kind"], payload))
    expected = [
        ("test", "function"), ("event", "runStarted"), ("event", "testStarted"),
        ("event", "issueRecorded"), ("event", "testEnded"), ("event", "runEnded"),
    ]
    if [(kind, body.get("kind")) for kind, body in records] != expected:
        raise TransportError("unexpected or incomplete native test lifecycle")
    return [payload for _, payload in records]


def inspected_endpoint(raw):
    document = decode_json(raw, "inspection")
    if not isinstance(document, dict) or type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
        raise TransportError("expected inspection schema 1")
    declarations = document.get("declarations")
    if not isinstance(declarations, list) or len(declarations) != 1:
        raise TransportError("expected one selected declaration")
    declaration = declarations[0]
    if (not isinstance(declaration, dict) or declaration.get("module") != MODULE
            or declaration.get("type") != PROTOCOL or declaration.get("generatedType") != PROTOCOL + "Mock"):
        raise TransportError("inspection selected another declaration")
    endpoints = declaration.get("endpoints")
    if not isinstance(endpoints, list):
        raise TransportError("inspection has no endpoint index")
    matches = [endpoint for endpoint in endpoints if isinstance(endpoint, dict) and endpoint.get("id") == SETTER]
    if len(matches) != 1:
        raise TransportError("expected one inspected static setter")
    endpoint = matches[0]
    if (endpoint.get("module") != MODULE or not isinstance(endpoint.get("file"), str)
            or not endpoint["file"] or type(endpoint.get("line")) is not int or endpoint["line"] <= 0
            or type(endpoint.get("column")) is not int or endpoint["column"] <= 0):
        raise TransportError("malformed inspected setter origin")
    return endpoint


def witness_source(generated, endpoint):
    matches = re.findall(r'let endpoint(\d+) = SyncEndpoint\(id: EndpointID\("' + re.escape(SETTER) + r'"\)', generated)
    if len(matches) != 1:
        raise TransportError("expected one declared setter in the generated mock")
    witnesses = re.findall(
        rf'scope\.__endpoint{matches[0]}\.invoke\([^\n]+, source: SourceLocation\('
        r'fileID: "([^"]+)", filePath: "([^"]+)", line: ([0-9]+), column: ([0-9]+)\)\)',
        generated,
    )
    if len(witnesses) != 1:
        raise TransportError("expected one source-bearing generated setter invocation")
    file_id, source_path, line, column = witnesses[0]
    basename = Path(endpoint["file"]).name
    if (file_id, source_path, int(line), int(column)) != (f"{MODULE}/{basename}", basename, endpoint["line"], 1):
        raise TransportError("generated source location disagrees with inspected declaration")
    # Inspection retains the setter token's column. Runtime diagnostics use the declaration's line start.
    return {"fileID": file_id, "_filePath": source_path, "line": int(line), "column": int(column)}


def validate(events, inspection, generated, runner_exit):
    if type(runner_exit) is not int or runner_exit != 1:
        raise TransportError(f"expected native status 1, observed {runner_exit}")
    discovery, _, start, event, end, _ = native_records(events)
    endpoint = inspected_endpoint(inspection)
    source = witness_source(generated, endpoint)
    test_id = discovery.get("id")
    if (discovery.get("name") != TEST or type(test_id) is not str
            or f".{TEST}/" not in test_id
            or any(payload.get("testID") != test_id for payload in (start, event, end))):
        raise TransportError("native failure did not belong to the selected test")
    issue = event.get("issue")
    messages = event.get("messages")
    if (not isinstance(issue, dict) or issue.get("isKnown") is not False
            or not isinstance(messages, list)
            or not any(isinstance(item, dict) and item.get("symbol") == "fail" for item in messages)):
        raise TransportError("expected one native unknown failure")
    if event.get("_sourceLocation") != source or issue.get("sourceLocation") != source:
        raise TransportError("native issue does not match the generated witness source")
    if event.get("_comments") != [f"Cannot call {SETTER} in a finished mock session"]:
        raise TransportError("native failure references another endpoint or failure")
    return {
        "nativeEventVersion": 0,
        "runnerExit": runner_exit,
        "testID": test_id,
        "endpoint": endpoint,
        "nativeSource": source,
        "nativeEventsSHA256": hashlib.sha256(events).hexdigest(),
    }


def read_bounded(path):
    with path.open("rb") as file:
        data = file.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise TransportError(f"{path.name} exceeds its byte limit")
    return data


def capture(command, *, cwd, env, watched=None, timeout=35):
    """Bound runner output and watch its own event artifact until process completion."""
    deadline = time.monotonic() + timeout
    received = bytearray()
    with subprocess.Popen(
        command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    ) as process, selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            while True:
                if watched is not None and watched.exists() and watched.stat().st_size > MAX_BYTES:
                    raise TransportError("native stream exceeds its byte limit during the run")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TransportError("capture deadline exceeded")
                if not selector.select(min(remaining, 0.1)):
                    continue
                chunk = os.read(process.stdout.fileno(), min(4096, MAX_BYTES + 1 - len(received)))
                if not chunk:
                    return process.wait(timeout=max(0, deadline - time.monotonic())), bytes(received)
                received.extend(chunk)
                if len(received) > MAX_BYTES:
                    raise TransportError("capture output exceeds its byte limit")
        finally:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)


def malformed_controls(events, inspection, generated, runner_exit):
    records = [json.loads(line) for line in events.splitlines()]
    issue, = (row["payload"] for row in records if row["payload"].get("kind") == "issueRecorded")
    issue["_sourceLocation"]["line"] += 1
    issue["issue"]["sourceLocation"]["line"] += 1
    wrong_location = b"".join(json.dumps(row).encode() + b"\n" for row in records)
    duplicate = re.sub(rb'"version"\s*:\s*0', rb'"version":0,"version":0', events, count=1)
    controls = (
        ("oversize-stream", b" " * (MAX_BYTES + 1), runner_exit, "native stream exceeds its byte limit"),
        ("oversize-record", b" " * (MAX_RECORD + 1) + b"\n", runner_exit, "native record 1 exceeds its byte limit"),
        ("truncated-line", events[:-1], runner_exit, "incomplete native stream"),
        ("malformed-json", events + b"{invalid record}\n", runner_exit, "invalid JSON"),
        ("duplicate-key", duplicate, runner_exit, "duplicate key"),
        ("missing-run-end", b"\n".join(events.splitlines()[:-1]) + b"\n", runner_exit, "native test lifecycle"),
        ("wrong-generated-origin", wrong_location, runner_exit, "does not match the generated witness source"),
        ("incorrect-zero-exit", events, 0, "expected native status 1"),
    )
    results = {}
    for name, data, status, expected in controls:
        try:
            validate(data, inspection, generated, status)
        except TransportError as error:
            if expected not in str(error):
                raise TransportError(f"{name} failed for the wrong reason: {error}") from error
            results[name] = str(error)
        else:
            raise TransportError(f"{name} unexpectedly produced an attribution result")
    return results


def verify(swift, tool, package, evidence):
    if sys.platform != "darwin":
        raise TransportError("this native Swift Testing qualification requires macOS")
    env = os.environ.copy()
    status, raw_version = capture([swift, "--version"], cwd=package, env=env, timeout=10)
    version = raw_version.decode("utf-8")
    release = re.search(r"\bSwift version (\d+)\.(\d+)", version)
    if status != 0 or not release or tuple(map(int, release.groups())) < (6, 4):
        raise TransportError("this native Swift Testing event schema requires Swift 6.4 or later")

    source = package / "Sources/ConsumerDomain/TypeSubscriptDirectory.swift"
    doubles = package / "Sources/ConsumerDoubles/TypeSubscriptDirectoryMock.swift"
    source_bytes, generated_bytes = read_bounded(source), read_bounded(doubles)
    generated = generated_bytes.decode("utf-8")
    with tempfile.TemporaryDirectory(prefix="dx028-native-origin-", dir=evidence) as temporary:
        work = Path(temporary)
        configuration = work / "blueprint-mocking.json"
        configuration.write_text(json.dumps({
            "schemaVersion": 1, "selections": [{"module": MODULE, "type": PROTOCOL, "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = work / "inspection-only-output"
        status, inspection = capture([
            tool, "inspect", "--config", configuration, "--output", output, "--input-set-id", "28",
            "--source", MODULE, source, "--format", "json",
        ], cwd=package, env=env, timeout=20)
        (evidence / "dx028-inspection.json").write_bytes(inspection)
        if status != 0 or output.exists():
            raise TransportError("fresh source inspection failed or created an output")

        native = work / "native-events.jsonl"
        status, logs = capture(
            native_test_command(swift, package, TEST.removesuffix("()"), native, skip_build=True),
            cwd=package, env=env | {"BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE": "1"}, watched=native,
        )
        (evidence / "dx028-native-runner.log").write_bytes(logs)
        events = read_bounded(native)
        (evidence / "dx028-native-events.jsonl").write_bytes(events)
        result = validate(events, inspection, generated, status)
        origin = configuration.parent / result["endpoint"]["file"]
        if origin.resolve() != source.resolve():
            raise TransportError("the inspected declaration does not refer to the supplied source")
        if read_bounded(source) != source_bytes or read_bounded(doubles) != generated_bytes:
            raise TransportError("qualification changed its authored or generated source")
        result["malformedControls"] = malformed_controls(events, inspection, generated, status)
        result["swiftVersion"] = version.strip()
        for name, contents in (
            ("inspection", inspection), ("runnerLog", logs), ("declarationSource", source_bytes),
            ("generatedSource", generated_bytes),
        ):
            result[name + "SHA256"] = hashlib.sha256(contents).hexdigest()
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--package", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    report = evidence / "dx028-native-generated-origin.json"
    report.unlink(missing_ok=True)
    try:
        result = verify(args.swift.absolute(), args.tool.resolve(strict=True), args.package.resolve(), evidence)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"DX028 native result transport failure: {error}", file=sys.stderr)
        return 2
    raw = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode()
    report.write_bytes(raw)
    print(f"EVIDENCE: {report.name} SHA-256 {hashlib.sha256(raw).hexdigest()}")
    print("PASS: DX028 native Swift Testing failure matches inspected generated origin")
    print("PASS: DX028 malformed native result streams failed explicitly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
