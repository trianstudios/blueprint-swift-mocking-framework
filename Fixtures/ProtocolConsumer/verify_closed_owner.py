#!/usr/bin/env python3
"""Qualify closed-case reporting with the pinned native Swift Testing event stream."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


TEST_FUNCTION = "DX023_closedParameterizedReporterAttribution"
OWNER = "owner-A"
PEER = "peer-B"


def native_test_command(swift, package, test, events_path, *, skip_build):
    command = [
        swift, "test", "--package-path", str(package), "--filter", test, "--disable-xctest",
        "--event-stream-output-path", str(events_path), "--event-stream-version", "0",
    ]
    if skip_build:
        command.append("--skip-build")
    return command


def event_payload(line):
    record = json.loads(line)
    if record["version"] != 0:
        raise ValueError("Unsupported Swift Testing event version")
    if record["kind"] == "event":
        return record["payload"]
    return None


def case_transition(event):
    if event is None or event["kind"] not in ("testCaseStarted", "testCaseEnded"):
        return None
    test_id = event["testID"]
    if f".{TEST_FUNCTION}(_:)/" not in test_id:
        raise ValueError(f"Unexpected native test {test_id}")
    test_case = event["_testCase"]
    argument = json.loads(test_case["displayName"])
    if argument not in (OWNER, PEER):
        raise ValueError(f"Unexpected native argument {argument}")
    return (event["kind"], argument), (test_id, test_case["id"])


def release_after_owner_ends(events_path, bridge, process, *, timeout):
    deadline = time.monotonic() + timeout
    ready_path = bridge / "peer-ready"
    transitions = {}
    offset = 0
    while time.monotonic() < deadline:
        if events_path.exists():
            with events_path.open("rb") as stream:
                stream.seek(offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    transition = case_transition(event_payload(line))
                    if transition:
                        key, identity = transition
                        if key in transitions:
                            raise ValueError(f"Duplicate native case transition {key}")
                        transitions[key] = identity

        if ("testCaseEnded", PEER) in transitions:
            raise ValueError("Peer case ended before the callback release")
        owner_end = transitions.get(("testCaseEnded", OWNER))
        peer_start = transitions.get(("testCaseStarted", PEER))
        if owner_end and peer_start and ready_path.exists():
            if transitions.get(("testCaseStarted", OWNER)) != owner_end:
                raise ValueError("Owner case-start and case-end identities differ")
            test_id, owner_case_id = owner_end
            peer_test_id, peer_case_id = peer_start
            if test_id != peer_test_id or not owner_case_id or not peer_case_id or owner_case_id == peer_case_id:
                raise ValueError("Expected distinct native cases with one native test ID")
            if ready_path.read_text(encoding="utf-8") != test_id:
                raise ValueError("Peer readiness witness had another native test ID")
            try:
                writer = os.open(bridge / "release", os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO:
                    raise
            else:
                with os.fdopen(writer, "wb") as gate:
                    gate.write(b"release\n")
                return
        if process.poll() is not None:
            raise ValueError("Native runner exited before the callback release")
        time.sleep(0.01)
    raise TimeoutError("Native case-end bridge did not release")


def validate_run(events_path, log_path, return_code, *, dropped_only):
    events = [event for line in events_path.read_bytes().splitlines() if (event := event_payload(line))]
    indexed = {}
    for index, event in enumerate(events):
        transition = case_transition(event)
        if transition:
            key, identity = transition
            if key in indexed:
                raise ValueError(f"Duplicate native case transition {key}")
            indexed[key] = index, identity
    if len(indexed) != 4:
        raise ValueError("Expected start and end events for both native cases")
    for argument in (OWNER, PEER):
        started, start_identity = indexed["testCaseStarted", argument]
        ended, end_identity = indexed["testCaseEnded", argument]
        if started >= ended or start_identity != end_identity:
            raise ValueError(f"Invalid native lifecycle for {argument}")
    issues = [(index, event) for index, event in enumerate(events) if event["kind"] == "issueRecorded"]
    if return_code != 1 or len(issues) != 1 or events[-1]["kind"] != "runEnded":
        raise ValueError("Expected one deliberate native run failure and a complete event stream")
    index, issue = issues[0]
    if not indexed["testCaseEnded", OWNER][0] < index < indexed["testCaseEnded", PEER][0]:
        raise ValueError("The run-level issue did not land between the native case completions")
    if issue.get("testID") is not None or issue.get("_testCase") is not None:
        raise ValueError("The closed owner issue was attributed to a native test or case")
    if issue["issue"]["isKnown"] is not False or not any(
        message["symbol"] == "fail" for message in issue["messages"]
    ):
        raise ValueError("Expected a native unknown failure")
    source = issue["_sourceLocation"]
    if (source["fileID"] != "BlueprintMockingTesting/Reporter.swift"
            or source["line"] <= 0 or source["column"] <= 0):
        raise ValueError("The native issue location must originate in the adapter")
    log = log_path.read_text(encoding="utf-8")
    marker = "PASS: DX023 owner closed while peer stayed active, one neutral issue"
    if log.count(marker) != 1:
        raise ValueError("Missing the callback and reporter ownership witness")
    uuid = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
    owners = re.findall(
        rf"^BLUEPRINT_CLOSED_OWNER session=({uuid}) epoch=(\d+) mock=(\d+) orphan=(\d+)$",
        log, re.MULTILINE,
    )
    if dropped_only:
        if owners:
            raise ValueError("Dropped-only flush unexpectedly retained an owner record")
        expected = "Blueprint Mocking dropped 1 orphan failures"
    else:
        if len(owners) != 1:
            raise ValueError("Missing original owner session, epoch, mock, and orphan metadata")
        session, epoch, mock, orphan = owners[0]
        expected = (
            f"Mock session {session}, epoch {epoch}, mock {mock}, orphan {orphan}: "
            "TypeSubscriptDirectory.swift:2:1: Cannot call schema1|ConsumerDomain.TypeSubscriptDirectory|"
            "type:subscript:(_:Int).set(_:Int,newValue:Int)->Void|Sendable in a finished mock session"
        )
    if issue.get("_comments") != [expected]:
        raise ValueError("Unexpected closed-session issue content")


def verify(swift, package, evidence, context, *, skip_build, dropped_only):
    qualifier = f"{context}-dropped-only" if dropped_only else context
    events_path = evidence / f"closed-owner-{qualifier}-events.jsonl"
    log_path = evidence / f"closed-owner-{qualifier}-runner.log"
    events_path.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"closed-owner-{qualifier}-", dir=evidence) as directory:
        bridge = Path(directory)
        pending_events = bridge / "native-events.jsonl"
        os.mkfifo(bridge / "release", mode=0o600)
        command = native_test_command(swift, package, TEST_FUNCTION, pending_events, skip_build=skip_build)
        env = os.environ | {
            "BLUEPRINT_CLOSED_OWNER_BRIDGE": directory,
            "BLUEPRINT_CLOSED_OWNER_CONTEXT": context,
            "BLUEPRINT_CLOSED_OWNER_DROPPED_ONLY": "1" if dropped_only else "0",
        }
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            )
            try:
                release_after_owner_ends(pending_events, bridge, process, timeout=35 if skip_build else 300)
                return_code = process.wait(timeout=35)
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=10)
                if pending_events.exists():
                    events_path.write_bytes(pending_events.read_bytes())
        validate_run(events_path, log_path, return_code, dropped_only=dropped_only)
    for artifact in (events_path, log_path):
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        print(f"EVIDENCE: {artifact.name} SHA-256 {digest}")
    classification = "dropped-only run-level issue" if dropped_only else "run-level issue"
    print(f"PASS: Swift Testing closed-owner {context} produced one {classification} and no case issues")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True, help="Path to the selected Swift executable")
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--context", choices=("detached", "inherited", "thread"), required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--dropped-only", action="store_true")
    options = parser.parse_args()
    evidence = options.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    verify(
        options.swift, Path(__file__).resolve().parent, evidence, options.context,
        skip_build=options.skip_build, dropped_only=options.dropped_only,
    )


if __name__ == "__main__":
    main()
