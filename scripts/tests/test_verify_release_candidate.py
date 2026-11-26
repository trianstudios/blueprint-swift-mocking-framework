"""Prepublish release-gate regressions using disposable repositories and signing keys."""

import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
GATE = PROJECT / "scripts" / "verify_release_candidate.py"
LEGACY_CHECKER = PROJECT / "scripts" / "check_release.py"
TAG_SIGNER = "fixture-release-signer"
RUNNER = "fixture-evidence-runner"
NAMESPACE = "blueprint-mocking-release-evidence"
PROFILE_ID = "fixture-macos-arm64"
CHECK = "fixture-passing-check"
PROFILE_FIELDS = {
    "compiler": "Swift 6 fixture compiler",
    "swift_syntax": "fixture SwiftSyntax",
    "host_os": "fixture macOS",
    "host_arch": "arm64",
    "sdk": "fixture SDK",
    "target": "arm64-apple-macos13",
    "language_mode": "6",
    "default_isolation": "nonisolated",
    "feature_flags": [],
    "test_runner": "fixture runner",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, sort_keys=True) + "\n", encoding="utf-8")


@unittest.skipUnless(shutil.which("git") and shutil.which("ssh-keygen"), "requires Git and ssh-keygen")
class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="blueprint-release-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.checkout = self.root / "candidate"
        self.evidence = self.root / "external-evidence"
        self.approval = self.root / "external-policy"
        for directory in (self.checkout, self.evidence, self.approval):
            directory.mkdir()
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_") and key != "SSH_AUTH_SOCK"
        }
        self.environment.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_NO_REPLACE_OBJECTS": "1",
        })

        self.tag_key = self.generate_key("tag")
        self.runner_key = self.generate_key("runner")
        self.tag_signers = self.approval / "tag-signers"
        self.runner_signers = self.approval / "runner-signers"
        self.allow(self.tag_signers, TAG_SIGNER, self.tag_key)
        self.allow(self.runner_signers, RUNNER, self.runner_key)

        self.git("init", "--quiet", "--template=")
        self.registry = self.checkout / "Docs" / "Acceptance-Status.csv"
        self.registry.parent.mkdir()
        self.rows = self.write_complete_registry()
        self.verifier = self.checkout / "scripts" / "verify.py"
        self.verifier.parent.mkdir()
        self.verifier.write_text("# Intentionally synthetic, externally approved test verifier.\n", encoding="utf-8")
        self.verifier_pin = digest(self.verifier)
        self.tracked_source = self.checkout / "source.txt"
        self.tracked_source.write_text("Fixture source A\n", encoding="utf-8")
        self.git("add", "Docs/Acceptance-Status.csv", "scripts/verify.py", "source.txt")
        self.git("commit", "--quiet", "-m", "Fixture A")
        self.revision = self.git("rev-parse", "HEAD")
        self.tag = "fixture-release-gate-a"
        self.tag_object = self.sign_tag(self.tag)
        self.build_signed_evidence()

    def call(self, command, *, check=True):
        process = subprocess.run(
            [str(value) for value in command],
            cwd=self.checkout,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if check:
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        return process

    def git(self, *arguments):
        return self.call([
            "git",
            "-c", f"core.hooksPath={os.devnull}",
            "-c", "user.name=Gate Fixture",
            "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgSign=false",
            "-c", "gpg.format=ssh",
            "-c", f"gpg.ssh.program={shutil.which('ssh-keygen')}",
            "-c", f"user.signingkey={self.tag_key}",
            *arguments,
        ]).stdout.strip()

    def generate_key(self, label):
        key = self.approval / f"{label}-key"
        self.call(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key])
        return key

    def allow(self, path, principal, key):
        public = key.with_suffix(".pub").read_text(encoding="utf-8").split()
        path.write_text(f"{principal} {public[0]} {public[1]}\n", encoding="utf-8")

    def sign_tag(self, name):
        self.git("tag", "-s", "-m", "Ephemeral gate fixture", name)
        return self.git("rev-parse", f"refs/tags/{name}")

    def write_complete_registry(self):
        with (PROJECT / "Docs" / "Acceptance-Status.csv").open(encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source)
            fieldnames = reader.fieldnames
            rows = list(reader)
        self.assertEqual(len(rows), 125)
        for row in rows:
            row["Implementation status"] = "Complete"
            row["Implementation references"] = "scripts/verify.py"
            row["Evidence checks"] = CHECK
        self.write_registry(rows, fieldnames)
        return rows

    def write_registry(self, rows, fieldnames):
        with self.registry.open("w", encoding="utf-8", newline="") as destination:
            writer = csv.DictWriter(destination, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

    def build_signed_evidence(self):
        self.log = self.evidence / "fixture.log"
        self.log.write_text("PASS: exact fixture revision\n", encoding="utf-8")
        result = {
            "check": CHECK,
            "passed": True,
            "exit": 0,
            "expected_failure": False,
            "log": self.log.name,
            "logSHA256": digest(self.log),
        }
        results = self.evidence / "results.json"
        write_json(results, [result])

        checkout_cut = {"revision": self.revision, "clean": True}
        profile = self.evidence / "profile.json"
        write_json(profile, {
            **PROFILE_FIELDS,
            "sourceRevision": self.revision,
            "checkoutBefore": checkout_cut,
            "checkoutAfter": checkout_cut,
            "resultsSHA256": digest(results),
            "acceptanceContractCount": 125,
        })

        artifacts = self.evidence / "contracts"
        artifacts.mkdir(exist_ok=True)
        contracts = {}
        for row in self.rows:
            feature = row["Feature ID"]
            gate = row["Acceptance gate"]
            artifact = artifacts / f"{feature}.json"
            write_json(artifact, {
                "schema": 1,
                "revision": self.revision,
                "feature_id": feature,
                "acceptance_gate": gate,
                "profile": PROFILE_FIELDS,
                "results": [result],
            })
            contracts[feature] = {
                "acceptance_gate": gate,
                "required_profiles": [PROFILE_ID],
                "evidence": {PROFILE_ID: {
                    "file": artifact.relative_to(self.evidence).as_posix(),
                    "sha256": digest(artifact),
                }},
            }
        self.certification = self.evidence / "certification.json"
        write_json(self.certification, {
            "schema": 1,
            "revision": self.revision,
            "profiles": {PROFILE_ID: PROFILE_FIELDS},
            "contracts": contracts,
        })

        attestation = self.evidence / "attestation.json"
        write_json(attestation, {
            "schema": 1,
            "revision": self.revision,
            "tag": self.tag,
            "tagObject": self.tag_object,
            "verifierSHA256": self.verifier_pin,
            "registrySHA256": digest(self.registry),
            "profileSHA256": digest(profile),
            "resultsSHA256": digest(results),
            "certificationSHA256": digest(self.certification),
        })
        attestation.with_suffix(".json.sig").unlink(missing_ok=True)
        self.call(["ssh-keygen", "-Y", "sign", "-n", NAMESPACE, "-f", self.runner_key, attestation])

    def run_gate(self, **overrides):
        options = {
            "checkout": self.checkout,
            "tag": self.tag,
            "evidence": self.evidence,
            "tag-signers": self.tag_signers,
            "runner-signers": self.runner_signers,
            "runner-id": RUNNER,
            "verifier-sha256": self.verifier_pin,
        }
        options.update(overrides)
        arguments = [item for key, value in options.items() for item in (f"--{key}", str(value))]
        return self.call([sys.executable, "-B", GATE, *arguments], check=False)

    def assert_rejects(self, result, diagnostic):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stderr, diagnostic)

    def test_accepts_the_clean_signed_and_strictly_ready_candidate(self):
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all"), "")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "ready")

    def test_rejects_consistent_old_signed_evidence_beside_newer_clean_checkout(self):
        # Candidate B keeps the same registry and verifier. Only its source identity changes.
        self.tracked_source.write_text("Fixture source B\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "-m", "Fixture B")
        new_revision = self.git("rev-parse", "HEAD")
        new_tag = "fixture-release-gate-b"
        self.sign_tag(new_tag)
        self.assertNotEqual(new_revision, self.revision)
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all"), "")

        # Standalone validation accepts the complete, internally consistent bundle at A.
        old_check = self.call([
            sys.executable, "-B", LEGACY_CHECKER, "--json",
            "--registry", self.registry, "--certification", self.certification, "--revision", self.revision,
        ])
        old_report = json.loads(old_check.stdout)
        self.assertEqual(old_report["state"], "ready")
        self.assertEqual(old_report["counts"]["certified"], 125)

        self.assert_rejects(self.run_gate(tag=new_tag), r"(?i)(revision|\bHEAD\b|tag object)")

    def test_rejects_valid_but_incomplete_signed_candidate(self):
        self.rows[0]["Implementation status"] = "Partial"
        self.write_registry(self.rows, list(self.rows[0]))
        self.git("add", "Docs/Acceptance-Status.csv")
        self.git("commit", "--quiet", "-m", "Fixture with incomplete acceptance")
        self.revision = self.git("rev-parse", "HEAD")
        self.tag = "fixture-release-gate-incomplete"
        self.tag_object = self.sign_tag(self.tag)
        self.build_signed_evidence()
        self.assert_rejects(self.run_gate(), r"(?i)(incomplete|ready|partial)")

    def test_rejects_dirty_checkout(self):
        self.tracked_source.write_text("uncommitted source\n", encoding="utf-8")
        self.assert_rejects(self.run_gate(), r"(?i)(dirty|clean|modified)")

    def test_rejects_a_tag_signer_outside_the_external_allowlist(self):
        self.allow(self.tag_signers, TAG_SIGNER, self.runner_key)
        self.assert_rejects(self.run_gate(), r"(?i)tag.*(signature|signer|verify|trust)")

    def test_rejects_a_runner_signer_outside_the_external_allowlist(self):
        self.allow(self.runner_signers, RUNNER, self.tag_key)
        self.assert_rejects(self.run_gate(), r"(?i)(runner|attestation).*(signature|signer|verify|trust)")

    def test_rejects_log_changed_after_a_valid_attestation(self):
        self.log.write_text("PASS: replaced output\n", encoding="utf-8")
        self.assert_rejects(self.run_gate(), r"(?i)(fixture\.log|log.*(digest|sha|hash))")

    def test_rejects_unapproved_verifier_pin(self):
        self.assert_rejects(self.run_gate(**{"verifier-sha256": "0" * 64}), r"(?i)verifier")

    def test_rejects_externally_named_evidence_resolving_inside_candidate(self):
        ignored = self.checkout / "ignored-evidence"
        real = self.git("rev-parse", "--absolute-git-dir")
        (Path(real) / "info").mkdir(exist_ok=True)
        (Path(real) / "info" / "exclude").write_text("/ignored-evidence/\n", encoding="utf-8")
        shutil.copytree(self.evidence, ignored)
        external_alias = self.root / "outside-alias"
        external_alias.symlink_to(ignored, target_is_directory=True)
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all"), "")
        self.assert_rejects(self.run_gate(evidence=external_alias), r"(?i)evidence.*(outside|checkout|inside)")


if __name__ == "__main__":
    unittest.main()
