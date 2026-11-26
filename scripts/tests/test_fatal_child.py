"""Focused tests for the bounded fatal-child verification gate."""

import os
from pathlib import Path
import signal
import sys
import unittest

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from fatal_child import check_fatal_child


ISSUE_LINE = "MOCK ISSUE: expected endpoint"
FATAL_LINE = "Probe.swift:7: Fatal error: expected endpoint"
DIAGNOSTICS = f"{ISSUE_LINE}\n{FATAL_LINE}\n"
ISSUE_PATTERN = r"(?m)^MOCK ISSUE: expected endpoint$"
FATAL_PATTERN = r"(?m)^Probe\.swift:7: Fatal error: expected endpoint$"

CHILD_PRELUDE = """
import os
import resource
import signal
import time

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
"""


@unittest.skipUnless(os.name == "posix" and hasattr(signal, "SIGTRAP"), "requires POSIX signals")
class FatalChildTests(unittest.TestCase):
    def run_child(self, script, *, timeout=10, maximum_stderr=4096):
        return check_fatal_child(
            [sys.executable, "-I", "-c", CHILD_PRELUDE + script],
            cwd=SCRIPT_DIR,
            issue_pattern=ISSUE_PATTERN,
            fatal_pattern=FATAL_PATTERN,
            expected_signal=signal.SIGTRAP,
            timeout=timeout,
            maximum_stderr=maximum_stderr,
        )

    def report_and_terminate(self, diagnostics=DIAGNOSTICS, *, fd=2, signame="SIGTRAP", **limits):
        return self.run_child(
            f"os.write({fd}, {diagnostics.encode()!r})\nos.kill(os.getpid(), signal.{signame})",
            **limits,
        )

    def test_rejects_ordinary_failure_even_with_expected_diagnostics(self):
        result = self.run_child(f"os.write(2, {DIAGNOSTICS.encode()!r})\nraise SystemExit(23)")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stderr, DIAGNOSTICS)
        self.assertIsNotNone(result.error)

    def test_rejects_unexpected_signal_even_with_expected_diagnostics(self):
        result = self.report_and_terminate(signame="SIGTERM")
        self.assertEqual(result.returncode, -signal.SIGTERM)
        self.assertEqual(result.stderr, DIAGNOSTICS)
        self.assertIsNotNone(result.error)

    def test_accepts_exact_signal_and_ordered_diagnostics_at_stderr_limit(self):
        result = self.report_and_terminate(maximum_stderr=len(DIAGNOSTICS.encode()))
        self.assertEqual(result.returncode, -signal.SIGTRAP)
        self.assertEqual(result.stderr, DIAGNOSTICS)
        self.assertIsNone(result.error)

    def test_rejects_reordered_duplicate_or_combined_diagnostics(self):
        for diagnostics in (
            f"{FATAL_LINE}\n{ISSUE_LINE}\n",
            f"{ISSUE_LINE}\n{DIAGNOSTICS}",
            f"{DIAGNOSTICS}{FATAL_LINE}\n",
            f"{ISSUE_LINE} {FATAL_LINE}\n",
        ):
            with self.subTest(diagnostics=diagnostics):
                result = self.report_and_terminate(diagnostics)
                self.assertEqual(result.returncode, -signal.SIGTRAP)
                self.assertIsNotNone(result.error)

    def test_diagnostics_on_stdout_do_not_count(self):
        result = self.report_and_terminate(fd=1)
        self.assertEqual(result.returncode, -signal.SIGTRAP)
        self.assertEqual(result.stderr, "")
        self.assertIsNotNone(result.error)

    def test_oversized_stderr_is_rejected_and_captured_output_stays_bounded(self):
        limit = 128
        result = self.run_child(
            f"os.write(2, {DIAGNOSTICS.encode()!r} + b'x' * 1048576)\n"
            "os.kill(os.getpid(), signal.SIGTRAP)",
            maximum_stderr=limit,
        )
        self.assertLessEqual(len(result.stderr.encode("utf-8")), limit)
        self.assertIsNotNone(result.error)

    def test_timeout_reaps_child_even_when_stderr_closed(self):
        result = self.run_child(
            f"os.write(2, {DIAGNOSTICS.encode()!r})\nos.close(2)\ntime.sleep(30)",
            timeout=0.5,
        )
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertIsNotNone(result.error)


if __name__ == "__main__":
    unittest.main()
