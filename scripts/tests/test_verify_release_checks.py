import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
SUITES = ("test_check_release.py", "test_verify_release_candidate.py")
REPORT = "release-checks.json"


@unittest.skipUnless(shutil.which("git"), "requires Git")
class ScopedReleaseChecksTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="Scoped Release Checks ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.checkout = self.root / "Fixture checkout"
        self.tests = self.checkout / "scripts/tests"
        self.tests.mkdir(parents=True)
        for name in ("verify.py", "check_release.py", "fatal_child.py"):
            shutil.copy2(SCRIPTS / name, self.checkout / "scripts" / name)

        self.evidence = self.root / "External Evidence"
        self.evidence.mkdir()
        self.report = self.evidence / REPORT
        self.executed = self.root / "executed-suites"
        self.selected_toolchain = self.root / "unexpected-toolchain-selection"
        tools = self.root / "Fixture tools"
        tools.mkdir()
        reject_toolchain = tools / "xcrun"
        reject_toolchain.write_text(
            '#!/bin/sh\n: > "$RELEASE_CHECK_FIXTURE_TOOLCHAIN_LOG"\nexit 91\n', encoding="utf-8",
        )
        reject_toolchain.chmod(0o755)

        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("GIT_", "BLUEPRINT_", "PYTHON"))
        } | {
            "PATH": str(tools) + os.pathsep + os.environ.get("PATH", os.defpath),
            "BLUEPRINT_EVIDENCE_DIRECTORY": str(self.evidence),
            "RELEASE_CHECK_FIXTURE_EXECUTION_LOG": str(self.executed),
            "RELEASE_CHECK_FIXTURE_TOOLCHAIN_LOG": str(self.selected_toolchain),
            "PYTHONDONTWRITEBYTECODE": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Scoped Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Scoped Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }

        self.git("init", "--quiet", "--template=")
        for name in SUITES:
            self.write_suite(name)
        self.revision = self.commit("Prepare scoped verification fixture")

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-c", f"core.hooksPath={os.devnull}", "-c", "core.autocrlf=false", *arguments],
            cwd=self.checkout, env=self.environment, text=True, timeout=10,
        ).strip()

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--quiet", "--no-gpg-sign", "-m", message)
        self.assertEqual(self.git("status", "--porcelain"), "")
        return self.git("rev-parse", "HEAD")

    def write_suite(self, name, *, failing=False, mutating=False):
        contents = """from pathlib import Path
import os
import unittest


class FixtureSuite(unittest.TestCase):
    def test_scoped_execution(self):
        self.assertEqual(Path.cwd().resolve(), Path(__file__).resolve().parents[2])
        with Path(os.environ["RELEASE_CHECK_FIXTURE_EXECUTION_LOG"]).open("a", encoding="utf-8") as log:
            print(Path(__file__).name, file=log)
"""
        if failing:
            contents += '        self.fail("intentional fixture failure")\n'
        if mutating:
            contents += '        (Path.cwd() / "child-created.txt").write_text("changed\\n", encoding="utf-8")\n'
        (self.tests / name).write_text(contents, encoding="utf-8")

    def run_scoped(self):
        self.report.write_text('{"status":"stale passing report"}\n', encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(self.checkout / "scripts/verify.py"), "--release-checks-only"],
            cwd=self.root, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=30, check=False,
        )

    def assert_scoped_side_effects(self):
        self.assertFalse(self.selected_toolchain.exists(), "Scoped verification tried to select a Swift toolchain")
        self.assertFalse((self.evidence / "profile.json").exists())
        self.assertFalse((self.evidence / "results.json").exists())

    def test_scoped_success_binds_clean_revision_and_two_log_hashes(self):
        completed = self.run_scoped()
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assert_scoped_side_effects()
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertCountEqual(self.executed.read_text(encoding="utf-8").splitlines(), SUITES)

        report = json.loads(self.report.read_bytes())
        expected_checkout = {"revision": self.revision, "clean": True}
        self.assertEqual(report["sourceRevision"], self.revision)
        self.assertEqual(report["checkoutBefore"], expected_checkout)
        self.assertEqual(report["checkoutAfter"], expected_checkout)
        self.assertEqual(report["status"], "local release checks")
        self.assertCountEqual([entry["check"] for entry in report["results"]], SUITES)
        for entry in report["results"]:
            with self.subTest(suite=entry["check"]):
                self.assertIs(entry["passed"], True)
                self.assertEqual(entry["exit"], 0)
                self.assertIs(entry["expected_failure"], False)
                self.assertEqual(entry["log"], entry["check"] + ".log")
                log = (self.evidence / entry["log"]).read_bytes()
                self.assertIn(b"Ran 1 test", log)
                self.assertEqual(entry["logSHA256"], hashlib.sha256(log).hexdigest())

    def test_failed_child_removes_stale_success_report(self):
        self.write_suite(SUITES[1], failing=True)
        self.commit("Make the candidate verification suite fail")
        completed = self.run_scoped()
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assert_scoped_side_effects()
        self.assertFalse(self.report.exists())
        self.assertCountEqual(self.executed.read_text(encoding="utf-8").splitlines(), SUITES)
        self.assertIn(b"intentional fixture failure", (self.evidence / (SUITES[1] + ".log")).read_bytes())

    def test_undiscovered_child_tests_cannot_publish_pass(self):
        (self.tests / SUITES[1]).write_text("# No test cases are available.\n", encoding="utf-8")
        self.commit("Make the candidate verification suite empty")
        completed = self.run_scoped()
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assert_scoped_side_effects()
        self.assertFalse(self.report.exists())
        self.assertEqual(self.executed.read_text(encoding="utf-8").splitlines(), [SUITES[0]])
        self.assertIn(b"Ran 0 tests", (self.evidence / (SUITES[1] + ".log")).read_bytes())

    def test_dirty_checkout_is_rejected_before_any_child_suite(self):
        (self.checkout / "untracked change.txt").write_text("dirty\n", encoding="utf-8")
        completed = self.run_scoped()
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assert_scoped_side_effects()
        self.assertFalse(self.report.exists())
        self.assertFalse(self.executed.exists())
        for name in SUITES:
            self.assertFalse((self.evidence / (name + ".log")).exists())

    def test_change_during_child_suite_invalidates_successful_checks(self):
        self.write_suite(SUITES[1], mutating=True)
        self.commit("Make a passing suite change its fixture checkout")
        completed = self.run_scoped()
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assert_scoped_side_effects()
        self.assertFalse(self.report.exists())
        self.assertTrue((self.checkout / "child-created.txt").is_file())
        self.assertCountEqual(self.executed.read_text(encoding="utf-8").splitlines(), SUITES)
        log = (self.evidence / (SUITES[1] + ".log")).read_bytes()
        self.assertIn(b"Ran 1 test", log)
        self.assertIn(b"OK", log)
