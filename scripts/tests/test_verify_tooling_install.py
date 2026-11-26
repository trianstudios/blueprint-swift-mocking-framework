from contextlib import contextmanager, redirect_stderr, redirect_stdout
import io
from pathlib import Path
import shutil
import sys
import tarfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import test_export_tooling as export_fixture
import verify_tooling_install as installer


REPORT = "tooling-install-report.json"
ARCHIVE_REJECTION = "Archive does not match the committed tooling export"


@unittest.skipUnless(shutil.which("git"), "requires Git")
class ToolingInstallPreflightTests(unittest.TestCase):
    def setUp(self):
        self.authoring = export_fixture.ToolingExportTests()
        self.addCleanup(self.authoring.doCleanups)
        self.authoring.setUp()
        self.repository = self.authoring.repository
        self.revision = self.authoring.revision
        self.root = self.authoring.root

        contents = export_fixture.build_archive(self.repository, self.revision)
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:") as archive:
            offset = archive.getmember(export_fixture.MAIN).offset_data
        corrupted = bytearray(contents)
        corrupted[offset] ^= 1
        self.corrupted = bytes(corrupted)
        self.archive = self.root / "corrupt export.tar"
        self.archive.write_bytes(self.corrupted)
        self.mirror = self.root / "unused SwiftSyntax mirror"
        self.mirror.mkdir()

    @contextmanager
    def forbid_install_steps(self):
        with (
            patch.object(installer, "swift_toolchain", side_effect=RuntimeError(
                "Swift selection attempted before archive validation",
            )) as swift,
            patch.object(installer.tempfile, "TemporaryDirectory", side_effect=AssertionError(
                "Installation scratch attempted before archive validation",
            )) as scratch,
            patch.object(installer, "export_repository", side_effect=AssertionError(
                "Extraction attempted before archive validation",
            )) as extraction,
        ):
            yield
            swift.assert_not_called()
            scratch.assert_not_called()
            extraction.assert_not_called()

    def run_main(self, evidence):
        arguments = [
            "verify_tooling_install.py", self.revision,
            "--archive", str(self.archive), "--swift-syntax-mirror", str(self.mirror),
            "--evidence-dir", str(evidence), "--repository", str(self.repository),
        ]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", arguments), redirect_stdout(stdout), redirect_stderr(stderr):
            status = installer.main()
        self.assertEqual(status, 1)
        self.assertEqual(stdout.getvalue(), "")
        return stderr.getvalue()

    def test_verify_rejects_corrupt_bytes_before_swift_scratch_or_extraction(self):
        evidence = self.root / "unused evidence directory"
        with self.forbid_install_steps():
            with self.assertRaisesRegex(ValueError, ARCHIVE_REJECTION):
                installer.verify(self.repository, self.revision, self.corrupted, self.mirror, evidence)
        self.assertFalse(evidence.exists())

    def test_main_preserves_existing_evidence_on_corrupt_archive(self):
        evidence = self.root / "existing evidence"
        evidence.mkdir()
        report = evidence / REPORT
        report.write_bytes(b'{"status":"previous verified install"}\n')
        original = report.read_bytes(), report.stat().st_mtime_ns

        with self.forbid_install_steps():
            stderr = self.run_main(evidence)
            self.assertTrue(report.is_file(), "Corrupt input removed the prior success report")
            self.assertEqual((report.read_bytes(), report.stat().st_mtime_ns), original)
            self.assertEqual(list(evidence.iterdir()), [report])
            self.assertIn(ARCHIVE_REJECTION, stderr)

    def test_main_does_not_create_fresh_evidence_on_corrupt_archive(self):
        evidence = self.root / "missing evidence parent" / "evidence"
        with self.forbid_install_steps():
            stderr = self.run_main(evidence)
            self.assertFalse(evidence.parent.exists(), "Corrupt input created the evidence directory")
            self.assertIn(ARCHIVE_REJECTION, stderr)
