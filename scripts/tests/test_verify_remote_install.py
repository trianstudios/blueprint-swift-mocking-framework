import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_remote_install as smoke


REVISION = "8937eb918955dc37404d0108bf6f89e21ed71ded"
MANIFEST = """dependencies: [.package(name: "BluepringMockingFramework", path: "../..")],
.product(name: "BluepringMockingFramework", package: "BluepringMockingFramework"),
.product(name: "BlueprintMockingTesting", package: "BluepringMockingFramework")
"""


class RemoteInstallTests(unittest.TestCase):
    def test_revision_manifest_preserves_product_names_while_changing_source_and_identity(self):
        manifest = smoke.rewrite_manifest(MANIFEST, REVISION)
        self.assertIn(f'.package(url: "{smoke.REMOTE_URL}", revision: "{REVISION}")', manifest)
        self.assertIn(f'.product(name: "BluepringMockingFramework", package: "{smoke.PACKAGE_ID}")', manifest)
        self.assertIn(f'.product(name: "BlueprintMockingTesting", package: "{smoke.PACKAGE_ID}")', manifest)
        self.assertNotIn('path: "../.."', manifest)

    def test_exact_manifest_rejects_malformed_versions_and_manifest_drift(self):
        for version in ("1", "01.2.3", "1.2.3-01", "1.2.3; false", "v1.2.3", "1.2.3-"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                smoke.rewrite_manifest(MANIFEST, REVISION, version)
        manifest = smoke.rewrite_manifest(MANIFEST, REVISION, "1.2.3-rc.1+build")
        self.assertIn('exact: "1.2.3-rc.1+build"', manifest)
        self.assertNotIn("revision:", manifest)

        with self.assertRaises(ValueError):
            smoke.rewrite_manifest(MANIFEST.replace("path", "url"), REVISION)
        with self.assertRaises(ValueError):
            smoke.rewrite_manifest(MANIFEST + MANIFEST, REVISION)
        with self.assertRaises(ValueError):
            smoke.rewrite_manifest(MANIFEST, "main")

    def test_resolved_pin_matches_public_identity_location_requirement_and_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "Package.resolved"
            pin = {
                "identity": smoke.PACKAGE_ID,
                "kind": "remoteSourceControl",
                "location": smoke.REMOTE_URL,
                "state": {"revision": REVISION, "version": "1.2.3"},
            }

            def write_pin(*pins):
                lock.write_text(json.dumps({"pins": list(pins), "version": 3}), encoding="utf-8")

            write_pin(pin)
            self.assertEqual(smoke.validate_lockfile(lock, REVISION, "1.2.3")["revision"], REVISION)
            with self.assertRaisesRegex(ValueError, "version"):
                smoke.validate_lockfile(lock, REVISION, "1.2.4")
            with self.assertRaisesRegex(ValueError, "revision"):
                smoke.validate_lockfile(lock, "0" * 40)
            write_pin(pin | {"location": "/tmp/local"})
            with self.assertRaisesRegex(ValueError, "location"):
                smoke.validate_lockfile(lock, REVISION)
            write_pin(pin | {"kind": "localSourceControl"})
            with self.assertRaisesRegex(ValueError, "kind"):
                smoke.validate_lockfile(lock, REVISION)
            write_pin(pin | {"identity": "bluepringmockingframework"})
            with self.assertRaisesRegex(ValueError, "identity"):
                smoke.validate_lockfile(lock, REVISION)
            write_pin(pin, pin)
            with self.assertRaisesRegex(ValueError, "identity"):
                smoke.validate_lockfile(lock, REVISION)

    def test_archive_rejects_links_and_path_traversal(self):
        for name, member_type in (
            ("Fixtures/RuntimeOnly/../../outside", tarfile.REGTYPE),
            ("Fixtures/RuntimeOnly/redirect", tarfile.SYMTYPE),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                content = io.BytesIO()
                with tarfile.open(fileobj=content, mode="w") as archive:
                    entry = tarfile.TarInfo(name)
                    entry.type = member_type
                    entry.linkname = "/tmp"
                    archive.addfile(entry)
                with self.assertRaises(ValueError):
                    smoke.extract_fixtures(content.getvalue(), Path(temporary))


if __name__ == "__main__":
    unittest.main()
