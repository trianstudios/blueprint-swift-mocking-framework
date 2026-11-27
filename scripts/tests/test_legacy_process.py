"""Test-first contract for the process-isolated legacy child harness."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import selectors
import sys
import tempfile
import time
import unittest

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from legacy_process import run_legacy_child


CHILD = """
import json
import os
import sys

def reply(result, **overrides):
    envelope = {
        "schema": 1,
        "requestID": os.environ["BLUEPRINT_LEGACY_REQUEST_ID"],
        "pid": os.getpid(),
        "result": result,
    }
    envelope.update(overrides)
    print(json.dumps(envelope), flush=True)
"""

SCOPED_CHILD = CHILD + """
active = None
observed_before = active
active = sys.argv[1]
with open(sys.argv[2], "wb", buffering=0) as ready:
    ready.write(b"1")
with open(sys.argv[3], "rb", buffering=0) as release:
    assert release.read(1) == b"1"
observed_during = active
active = None
reply({"before": observed_before, "during": observed_during, "after": active, "child": os.getpid()})
raise SystemExit(int(sys.argv[4]))
"""


@unittest.skipUnless(os.name == "posix", "initial legacy-child lane uses POSIX process groups")
class LegacyChildTests(unittest.TestCase):
    def run_child(self, script, *args, timeout=4, maximum_output=1024):
        command = [sys.executable, "-I", "-c", script, *map(str, args)]
        return run_legacy_child(command, cwd=Path(__file__).parent,
                                timeout=timeout, maximum_output=maximum_output)

    def overlapping(self, second_exit):
        with tempfile.TemporaryDirectory() as temporary:
            paths = []
            descriptors = []
            for label in ("first", "second"):
                ready = Path(temporary) / f"{label}-ready"
                release = Path(temporary) / f"{label}-release"
                for path in (ready, release):
                    os.mkfifo(path)
                    descriptors.append(os.open(path, os.O_RDWR | os.O_NONBLOCK))
                paths.append((ready, release))
            try:
                with ThreadPoolExecutor(max_workers=2) as pool, selectors.DefaultSelector() as ready:
                    ready.register(descriptors[0], selectors.EVENT_READ)
                    ready.register(descriptors[2], selectors.EVENT_READ)
                    first = pool.submit(self.run_child, SCOPED_CHILD, "first scope", *paths[0], 0)
                    second = pool.submit(self.run_child, SCOPED_CHILD, "second scope", *paths[1], second_exit)
                    try:
                        deadline = time.monotonic() + 3
                        while ready.get_map():
                            events = ready.select(max(0, deadline - time.monotonic()))
                            self.assertTrue(events, "both children must hold different live scopes simultaneously")
                            for key, _ in events:
                                self.assertEqual(os.read(key.fd, 1), b"1")
                                ready.unregister(key.fd)
                    finally:
                        os.write(descriptors[1], b"1")
                        os.write(descriptors[3], b"1")
                    return first.result(), second.result()
            finally:
                for descriptor in descriptors:
                    os.close(descriptor)

    def test_two_live_static_scopes_return_independent_results(self):
        first, second = self.overlapping(0)
        for returned, expected in ((first, "first scope"), (second, "second scope")):
            self.assertIsNone(returned.error)
            self.assertEqual(returned.returncode, 0)
            self.assertIsNone(returned.payload["before"])
            self.assertEqual(returned.payload["during"], expected)
            self.assertIsNone(returned.payload["after"])
            self.assertNotEqual(returned.payload["child"], os.getpid())
        self.assertNotEqual(first.payload["child"], second.payload["child"])

    def test_plausible_nonzero_peer_does_not_reclassify_other_result(self):
        first, second = self.overlapping(23)
        self.assertIsNone(first.error)
        self.assertEqual(first.payload["during"], "first scope")
        self.assertEqual(second.returncode, 23)
        self.assertIsNotNone(second.error)
        self.assertIsNone(second.payload)

    def test_wrong_scope_token_pid_or_duplicate_envelope_rejects_success(self):
        for forged in (
            'reply("ok", requestID="wrong")',
            'reply("ok", pid=os.getppid())',
            'reply("ok", schema=True)',
            'reply("ok"); reply("ok")',
            'print("{broken")',
        ):
            with self.subTest(forged=forged):
                child = self.run_child(CHILD + forged)
                self.assertEqual(child.returncode, 0)
                self.assertIsNotNone(child.error)
                self.assertIsNone(child.payload)

    def test_literal_arguments_are_data(self):
        value = "a value with spaces & one ; literal token"
        child = self.run_child(CHILD + "reply(sys.argv[1])", value)
        self.assertIsNone(child.error)
        self.assertEqual(child.payload, value)

    def test_timeout_applies_after_result_and_output_limit_applies_to_either_stream(self):
        child = self.run_child(CHILD + 'reply("ok")\nimport time\ntime.sleep(30)', timeout=0.2)
        self.assertIn("deadline", child.error)
        self.assertIsNone(child.payload)
        for fd in (1, 2):
            with self.subTest(fd=fd):
                child = self.run_child(CHILD + f'os.write({fd}, b"x" * 8192)', maximum_output=128)
                self.assertIsNotNone(child.error)
                self.assertIsNone(child.payload)
