"""Acceptance tests for the release certification command."""
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check_release.py"
REPO = SCRIPT.parent.parent
REVISION = "2" * 40
PROFILE = {
    "compiler": "Apple Swift 6.4 (swiftlang-example)",
    "swift_syntax": "toolchain build example",
    "host_os": "macOS 27",
    "host_arch": "arm64",
    "sdk": "macOS 27 SDK",
    "target": "arm64-apple-macos13",
    "language_mode": "6",
    "default_isolation": "nonisolated",
    "feature_flags": [],
    "test_runner": "Swift Testing example",
}


class ReleaseCheckTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.registry = self.root / "registry.csv"
        self.plan = self.root / "certification.json"
        self.report = self.root / "report.json"
        with (REPO / "Docs" / "Acceptance-Status.csv").open(newline="", encoding="utf-8") as file:
            reader = csv.DictReader(file)
            self.columns = reader.fieldnames
            self.rows = list(reader)
        for row in self.rows:
            row["Implementation status"] = "Unimplemented"

    def write_registry(self):
        with self.registry.open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=self.columns)
            writer.writeheader()
            writer.writerows(self.rows)

    def run_check(self, *args, evidence=False):
        self.write_registry()
        command = [sys.executable, str(SCRIPT), "--registry", str(self.registry), "--json", *args]
        if evidence:
            command += ["--certification", str(self.plan), "--revision", REVISION]
        process = subprocess.run(command, check=False, capture_output=True, text=True)
        self.assertTrue(process.stdout, process.stderr)
        return process.returncode, json.loads(process.stdout)

    def prepare_claim(self, *, gate=None, result=None, manifest_digest=None, profile=None):
        row = self.rows[0]
        row["Implementation status"] = "Complete"
        row["Implementation references"] = "Tooling/GenerateMocks.swift"
        row["Evidence checks"] = "consumer-tests"
        gate = gate if gate is not None else row["Acceptance gate"]
        profile = profile if profile is not None else PROFILE
        result = result if result is not None else {"check": "consumer-tests", "passed": True, "exit": 0,
                                                    "expected_failure": False}
        self.report.write_text(json.dumps({
            "schema": 1,
            "feature_id": row["Feature ID"],
            "acceptance_gate": gate,
            "revision": REVISION,
            "profile": profile,
            "results": [result],
        }), encoding="utf-8")
        digest = manifest_digest or hashlib.sha256(self.report.read_bytes()).hexdigest()
        self.plan.write_text(json.dumps({
            "schema": 1,
            "revision": REVISION,
            "profiles": {"macos-arm64": profile},
            "contracts": {
                row["Feature ID"]: {
                    "acceptance_gate": gate,
                    "required_profiles": ["macos-arm64"],
                    "evidence": {"macos-arm64": {"file": self.report.name, "sha256": digest}},
                }
            },
        }), encoding="utf-8")

    def test_partial_registry_is_reviewable_but_blocks_release(self):
        self.rows[0]["Implementation status"] = "Partial"
        exit_code, result = self.run_check()
        self.assertEqual(exit_code, 1)
        self.assertEqual(result["state"], "incomplete")
        self.assertEqual(result["counts"], {"certified": 0, "partial": 1, "unimplemented": 124})
        self.assertEqual(result["errors"], [])
        self.assertEqual(self.run_check("--report-only")[0], 0)

    def test_preserves_exact_ids_not_merely_the_total(self):
        self.rows[-1]["Feature ID"] = "DX-999"
        exit_code, result = self.run_check()
        self.assertEqual(exit_code, 2)
        self.assertEqual(result["state"], "invalid")
        self.assertIn("DX-034", " ".join(result["errors"]))
        self.assertIn("DX-999", " ".join(result["errors"]))

    def test_duplicates_and_unknown_status_are_invalid(self):
        self.rows[-1]["Feature ID"] = self.rows[0]["Feature ID"]
        self.rows[0]["Implementation status"] = "Certified someday"
        exit_code, result = self.run_check("--report-only")
        self.assertEqual(exit_code, 2)
        self.assertIn("duplicate", " ".join(result["errors"]))
        self.assertIn("Certified someday", " ".join(result["errors"]))

    def test_completed_claim_requires_evidence_and_profiles(self):
        self.rows[0]["Implementation status"] = "Complete"
        self.rows[0]["Implementation references"] = "Tooling/GenerateMocks.swift"
        self.rows[0]["Evidence checks"] = "consumer-tests"
        exit_code, result = self.run_check()
        self.assertEqual(exit_code, 2)
        self.assertEqual(result["counts"]["certified"], 0)
        self.assertIn("SYS-001", " ".join(result["errors"]))

    def test_verifies_bound_passing_evidence_per_profile(self):
        self.prepare_claim()
        exit_code, result = self.run_check(evidence=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["counts"]["certified"], 1)
        self.assertEqual(self.run_check(evidence=True)[1], result)

    def test_expected_compiler_failure_can_be_passing_evidence(self):
        self.prepare_claim(result={
            "check": "consumer-tests", "passed": True, "exit": 1, "expected_failure": True,
        })
        exit_code, result = self.run_check(evidence=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(result["counts"]["certified"], 1)

    def test_wrong_release_revision_invalidates_the_claim(self):
        self.prepare_claim()
        self.write_registry()
        process = subprocess.run([
            sys.executable, str(SCRIPT), "--registry", str(self.registry), "--json",
            "--certification", str(self.plan), "--revision", "3" * 40,
        ], capture_output=True, check=False, text=True)
        self.assertEqual(process.returncode, 2)
        result = json.loads(process.stdout)
        self.assertIn("revision does not match", " ".join(result["errors"]))

    def test_rejects_missing_required_profile_evidence(self):
        self.prepare_claim()
        plan = json.loads(self.plan.read_text())
        plan["profiles"]["other"] = {**PROFILE, "host_arch": "x86_64"}
        plan["contracts"]["SYS-001"]["required_profiles"].append("other")
        self.plan.write_text(json.dumps(plan))
        self.assertEqual(self.run_check(evidence=True)[0], 2)

    def test_rejects_evidence_from_a_different_profile(self):
        self.prepare_claim()
        plan = json.loads(self.plan.read_text())
        plan["profiles"]["macos-arm64"]["sdk"] = "older SDK"
        self.plan.write_text(json.dumps(plan))
        self.assertEqual(self.run_check(evidence=True)[0], 2)

    def test_rejects_wrong_gate_failed_check_or_corrupted_evidence(self):
        for variant in (
            {"gate": "A different gate"},
            {"result": {"check": "consumer-tests", "passed": False, "exit": 1, "expected_failure": False}},
            {"result": {"check": "another-check", "passed": True, "exit": 0, "expected_failure": False}},
            {"manifest_digest": "0" * 64},
        ):
            with self.subTest(variant=variant):
                self.prepare_claim(**variant)
                self.assertEqual(self.run_check(evidence=True)[0], 2)

    def test_rejects_blank_implementation_reference_with_valid_artifacts(self):
        self.prepare_claim()
        self.rows[0]["Implementation references"] = ""
        exit_code, result = self.run_check(evidence=True)
        self.assertEqual(exit_code, 2)
        self.assertEqual(result["counts"]["certified"], 0)
        self.assertEqual(result["errors"], [
            "SYS-001: completed contract needs implementation references and unique evidence checks"
        ])

    def test_rejects_blank_check_names_with_valid_artifacts(self):
        self.prepare_claim()
        self.rows[0]["Evidence checks"] = ""
        exit_code, result = self.run_check(evidence=True)
        self.assertEqual(exit_code, 2)
        self.assertEqual(result["counts"]["certified"], 0)
        self.assertEqual(result["errors"], [
            "SYS-001: completed contract needs implementation references and unique evidence checks"
        ])


if __name__ == "__main__":
    unittest.main()
