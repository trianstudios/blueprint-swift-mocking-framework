"""Exercise exact-revision tooling source exports using disposable Git repositories."""

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from export_tooling import build_archive, unpack_verified_archive, verify_archive


TOOLING = "Packages/Tooling"
MANIFEST_PATH = f"{TOOLING}/ExportManifest.json"
PROVENANCE_PATH = "BlueprintToolingExport.json"
MAIN = "Sources/BlueprintMockingCLI/main.swift"
PLUGIN = "Plugins/BlueprintMockingBuildPlugin/plugin.swift"
FILES = {
    "Package.swift": b"// swift-tools-version: 6.0\n",
    MAIN: b"// Source A $Format:%H$\n",
    PLUGIN: b"// Build tool plugin A\n",
}
LICENSE = b"MIT License\nFixture copyright\n"
MANIFEST = {
    "schema": 1,
    "files": list(FILES),
    "compatibility": {
        "runtimeProduct": "BluepringMockingFramework",
        "runtimeModule": "BlueprintMocking",
        "endpointSchema": 1,
        "swiftLanguageMode": "6",
        "swiftSyntax": {
            "url": "https://github.com/swiftlang/swift-syntax.git",
            "version": "600.0.1",
            "revision": "0687f71944021d616d34d922343dcef086855920",
        },
    },
}


@unittest.skipUnless(shutil.which("git"), "requires Git")
class ToolingExportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="blueprint tooling export ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repository = self.root / "authoring checkout"
        self.repository.mkdir()
        self.git_environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.git_environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        self.git("init", "--quiet", "--template=")
        self.write("LICENSE", LICENSE)
        self.write("Private.txt", b"Not part of the tooling distribution.\n")
        for name, contents in FILES.items():
            self.write(f"{TOOLING}/{name}", contents)
        self.write_manifest(MANIFEST)
        self.revision = self.commit("Authoring revision A")

    def git(self, *arguments):
        return subprocess.check_output([
            "git", "-c", f"core.hooksPath={os.devnull}", "-c", "commit.gpgSign=false",
            "-c", "core.autocrlf=false", "-c", "user.name=Tooling Fixture",
            "-c", "user.email=fixture@example.invalid", *arguments,
        ], cwd=self.repository, env=self.git_environment, text=True, timeout=15).strip()

    def write(self, path, contents):
        target = self.repository / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
        return target

    def write_manifest(self, manifest):
        self.write(MANIFEST_PATH, (json.dumps(manifest) + "\n").encode("utf-8"))

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_repeatable_across_checkout_and_destination_paths_with_exact_provenance(self):
        relocated = self.root / "separate authoring checkout"
        shutil.copytree(self.repository, relocated)
        contents = build_archive(self.repository, self.revision)
        self.assertEqual(contents, build_archive(relocated, self.revision))

        expected_files = FILES | {"LICENSE": LICENSE}
        provenance = verify_archive(contents, self.repository, self.revision)
        self.assertEqual(provenance["authoringRevision"], self.revision)
        self.assertEqual(provenance["packageIdentity"], "blueprint-swift-mocking-tools")
        self.assertEqual(provenance["compatibility"], MANIFEST["compatibility"])
        self.assertEqual(len(provenance["files"]), len(expected_files))
        self.assertEqual({entry["path"]: (entry["source"], entry["sha256"]) for entry in provenance["files"]}, {
            name: ("LICENSE" if name == "LICENSE" else f"{TOOLING}/{name}", hashlib.sha256(data).hexdigest())
            for name, data in expected_files.items()
        })

        for destination in (self.root / "first export", self.root / "other directory" / "second export"):
            with self.subTest(destination=destination.name):
                destination.parent.mkdir(exist_ok=True)
                unpack_verified_archive(contents, destination, relocated, self.revision)
                self.assertEqual({file.relative_to(destination).as_posix() for file in destination.rglob("*")
                                  if file.is_file()}, set(expected_files) | {PROVENANCE_PATH})
                for name, data in expected_files.items():
                    self.assertEqual((destination / name).read_bytes(), data)
                self.assertEqual(json.loads((destination / PROVENANCE_PATH).read_bytes()), provenance)

    def test_export_ignores_working_tree_index_untracked_files_and_archive_attributes(self):
        committed = build_archive(self.repository, self.revision)
        source = f"{TOOLING}/{MAIN}"
        self.write(source, b"Staged but never committed\n")
        self.git("add", source)
        self.write(source, b"Working copy only\n")
        self.write(f"{TOOLING}/Sources/BlueprintMockingCLI/Untracked.swift", b"Untracked only\n")
        self.write("LICENSE", b"Working copy license only\n")
        self.write(".git/info/attributes", f"{source} export-subst\nLICENSE export-ignore\n".encode("utf-8"))

        self.assertEqual(build_archive(self.repository, self.revision), committed)
        destination = self.root / "unpacked committed sources"
        unpack_verified_archive(committed, destination, self.repository, self.revision)
        self.assertEqual((destination / MAIN).read_bytes(), FILES[MAIN])
        self.assertEqual((destination / "LICENSE").read_bytes(), LICENSE)

    def test_internally_consistent_older_archive_cannot_verify_as_newer_revision(self):
        older = build_archive(self.repository, self.revision)
        self.write("Private.txt", b"New revision with unchanged tooling sources.\n")
        newer_revision = self.commit("Authoring revision B")
        newer = build_archive(self.repository, newer_revision)

        self.assertNotEqual(older, newer)
        older_manifest = verify_archive(older, self.repository, self.revision)
        newer_manifest = verify_archive(newer, self.repository, newer_revision)
        self.assertEqual(older_manifest["files"], newer_manifest["files"])
        self.assertEqual(newer_manifest["authoringRevision"], newer_revision)
        with self.assertRaises(ValueError):
            verify_archive(older, self.repository, newer_revision)

    def test_corrupted_archive_is_rejected_before_destination_is_created(self):
        contents = build_archive(self.repository, self.revision)
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:") as archive:
            member = archive.getmember(MAIN)
        damaged = bytearray(contents)
        damaged[member.offset_data] ^= 1
        destination = self.root / "must not be created"

        with self.assertRaises(ValueError):
            unpack_verified_archive(bytes(damaged), destination, self.repository, self.revision)
        self.assertFalse(destination.exists())

    def test_manifest_cannot_select_a_file_outside_tooling_directory(self):
        altered = copy.deepcopy(MANIFEST)
        altered["files"].append("../../Private.txt")
        self.write_manifest(altered)
        revision = self.commit("Invalid export path")

        with self.assertRaises(ValueError):
            build_archive(self.repository, revision)

    def test_manifest_cannot_export_a_committed_symlink(self):
        (self.repository / TOOLING / MAIN).unlink()
        (self.repository / TOOLING / MAIN).symlink_to("../../../../Private.txt")
        revision = self.commit("Selected source is a symlink")

        with self.assertRaises(ValueError):
            build_archive(self.repository, revision)


if __name__ == "__main__":
    unittest.main()
