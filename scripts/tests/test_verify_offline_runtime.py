import errno
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zlib


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from verify_offline_runtime import (
    offline_git_environment, validate_linkage, validate_mirror_revision, validate_network_probe,
)


RUNTIME_LIBRARY = b"\t/usr/lib/swift/libswiftCore.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
OTOOL = b"/tmp/RuntimeOnly:\n" + RUNTIME_LIBRARY
BLUEPRINT_OBJECT = b"/tmp/Build Products/BlueprintMocking.build/Runtime.swift.o\n"
CONSUMER_OBJECT = b"/tmp/Build Products/RuntimeOnly.build/main.swift.o\n"


class LinkageTests(unittest.TestCase):
    def test_accepts_only_runtime_and_consumer_objects(self):
        validate_linkage(OTOOL, BLUEPRINT_OBJECT + CONSUMER_OBJECT)

    def test_accepts_linker_quoted_object_paths_with_spaces(self):
        core = b"'" + BLUEPRINT_OBJECT.rstrip() + b"'\n"
        consumer = b'"' + CONSUMER_OBJECT.rstrip() + b'"\n'
        validate_linkage(OTOOL, core + consumer)

    def test_rejects_parser_generator_and_reporter_libraries(self):
        for library in (
            b"@rpath/libSwiftSyntax.dylib",
            b"@rpath/libSwiftParser.dylib",
            b"@rpath/SourceKit.framework/SourceKit",
            b"@rpath/libsourcekitdInProc.dylib",
            b"@rpath/libTesting.dylib",
            b"@rpath/libBlueprintMockingTesting.dylib",
            b"@rpath/XCTest.framework/XCTest",
            b"@rpath/blueprint-mocking",
            b"@rpath/libBlueprintMockingCLI.dylib",
        ):
            with self.subTest(library=library):
                dynamic = OTOOL + b"\t" + library + b" (compatibility version 1.0.0, current version 1.0.0)\n"
                with self.assertRaises(ValueError):
                    validate_linkage(dynamic, BLUEPRINT_OBJECT + CONSUMER_OBJECT)

    def test_requires_at_least_one_actual_macho_load_command(self):
        for empty in (b"", b"/tmp/RuntimeOnly:\n", b"/tmp/RuntimeOnly:\nnot a load command\n"):
            with self.subTest(dynamic=empty), self.assertRaises(ValueError):
                validate_linkage(empty, BLUEPRINT_OBJECT + CONSUMER_OBJECT)

    def test_rejects_unrelated_object_even_when_both_expected_targets_appear(self):
        objects = BLUEPRINT_OBJECT + b"/tmp/Build Products/Other.build/Dependency.swift.o\n" + CONSUMER_OBJECT
        with self.assertRaises(ValueError):
            validate_linkage(OTOOL, objects)

    def test_requires_objects_from_both_runtime_and_consumer_targets(self):
        for incomplete in (b"", BLUEPRINT_OBJECT, CONSUMER_OBJECT):
            with self.subTest(objects=incomplete), self.assertRaises(ValueError):
                validate_linkage(OTOOL, incomplete)


class MirrorRevisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="Offline Runtime Mirror ")
        cls.addClassCleanup(directory.cleanup)
        root = Path(directory.name)
        cls.source = root / "Author Repository"
        cls.source.mkdir()
        cls.mirror = root / "Prepared Runtime.git"
        cls.environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")} | {
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Local Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Local Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        cls.git("init", "--quiet", "--template=")
        (cls.source / "fixture.txt").write_text("prepared source\n", encoding="utf-8")
        cls.git("add", "fixture.txt")
        cls.git("commit", "--quiet", "--no-gpg-sign", "-m", "Prepare source")
        cls.git("tag", "-a", "prepared", "-m", "Prepared revision")
        cls.revision = cls.git("rev-parse", "HEAD")
        cls.blob = cls.git("rev-parse", "HEAD:fixture.txt")
        cls.tag = cls.git("rev-parse", "refs/tags/prepared")
        cls.git("clone", "--bare", "--quiet", str(cls.source), str(cls.mirror))

    @classmethod
    def git(cls, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(cls.source), *arguments], env=cls.environment, text=True, timeout=10,
        ).strip()

    def test_accepts_exact_commit_in_prepared_bare_mirror(self):
        validate_mirror_revision(self.mirror, self.revision, self.environment)

    def test_rejects_a_worktree_even_when_it_contains_the_exact_commit(self):
        with self.assertRaises(ValueError):
            validate_mirror_revision(self.source, self.revision, self.environment)

    def test_requires_a_present_commit_object_without_implicit_peeling(self):
        for revision in ("0" * 40, self.blob, self.tag, "HEAD"):
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                validate_mirror_revision(self.mirror, revision, self.environment)

    def test_rejects_hash_mismatched_blob_under_a_present_commit(self):
        with tempfile.TemporaryDirectory(prefix="Corrupted Runtime Mirror ") as directory:
            mirror = Path(directory) / "Runtime.git"
            self.git("clone", "--bare", "--local", "--no-hardlinks", "--quiet", str(self.source), str(mirror))
            loose_blob = mirror / "objects" / self.blob[:2] / self.blob[2:]
            header, payload = zlib.decompress(loose_blob.read_bytes()).split(b"\0", 1)
            damaged_payload = b"modified source\n"
            self.assertEqual(header, f"blob {len(damaged_payload)}".encode())
            self.assertNotEqual(payload, damaged_payload)
            replacement = mirror / "tampered-blob"
            replacement.write_bytes(zlib.compress(header + b"\0" + damaged_payload))
            replacement.replace(loose_blob)

            git = ["git", "-C", str(mirror), "cat-file"]
            self.assertEqual(subprocess.check_output(
                [*git, "-t", self.revision], env=self.environment, timeout=10,
            ), b"commit\n")
            self.assertEqual(subprocess.check_output(
                [*git, "blob", self.blob], env=self.environment, timeout=10,
            ), damaged_payload)
            with self.assertRaisesRegex(ValueError, r"^Runtime mirror failed Git object integrity check"):
                validate_mirror_revision(mirror, self.revision, self.environment)

    def test_exact_fixture_reads_ignore_replacement_refs(self):
        (self.source / "fixture.txt").write_text("replacement source\n", encoding="utf-8")
        self.git("add", "fixture.txt")
        self.git("commit", "--quiet", "--no-gpg-sign", "-m", "Substitute fixture")
        self.git("replace", self.revision, "HEAD")
        self.addCleanup(self.git, "replace", "-d", self.revision)

        self.assertEqual(self.git("rev-parse", self.revision), self.revision)
        self.assertEqual(self.git("show", f"{self.revision}:fixture.txt"), "replacement source")
        read = subprocess.check_output(
            ["git", "-C", str(self.source), "show", f"{self.revision}:fixture.txt"],
            env=offline_git_environment(self.environment), timeout=10,
        )
        self.assertEqual(read, b"prepared source\n")


class OfflineGitEnvironmentTests(unittest.TestCase):
    def test_removes_all_ambient_git_overrides_but_preserves_toolchain_environment(self):
        policy = {
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_PROTOCOL_FROM_USER": "0",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        }
        overrides = {
            "GIT_DIR": "/ambient/git-directory",
            "GIT_WORK_TREE": "/ambient/worktree",
            "GIT_OBJECT_DIRECTORY": "/ambient/object-directory",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/ambient/alternate-object-directory",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "include.path",
            "GIT_CONFIG_VALUE_0": "/ambient/configuration",
            "GIT_REPLACE_REF_BASE": "refs/ambient/",
            "GIT_ADDITIONAL_FIXTURE_OVERRIDE": "unexpected ambient value",
        }
        ambient = {"SWIFT_EXEC": "/selected/swiftc", "SDKROOT": "/selected/SDK"} | overrides | {
            key: "ambient policy" for key in policy
        }
        original = ambient.copy()
        filtered = offline_git_environment(ambient)
        self.assertEqual(ambient, original)
        self.assertEqual({key: filtered.get(key) for key in policy}, policy)
        self.assertFalse(overrides.keys() & filtered.keys())
        self.assertEqual(filtered["SWIFT_EXEC"], "/selected/swiftc")
        self.assertEqual(filtered["SDKROOT"], "/selected/SDK")


class NetworkProbeTests(unittest.TestCase):
    def setUp(self):
        self.connected = subprocess.CompletedProcess(["probe"], 0, b"BLUEPRINT_LOOPBACK_CONNECTED\n", b"")
        self.denied = subprocess.CompletedProcess(
            ["sandbox", "probe"], errno.EPERM, b"BLUEPRINT_LOOPBACK_ERRNO=1\n", b"",
        )

    def test_requires_a_working_baseline_and_permission_denial_under_policy(self):
        for status in (errno.EPERM, errno.EACCES):
            with self.subTest(status=status):
                validate_network_probe(self.connected, subprocess.CompletedProcess(
                    ["sandbox", "probe"], status, f"BLUEPRINT_LOOPBACK_ERRNO={status}\n".encode(), b"",
                ))

    def test_rejects_failed_baseline_even_with_apparent_permission_denial(self):
        direct = subprocess.CompletedProcess(["probe"], errno.ECONNREFUSED, b"", b"")
        with self.assertRaises(ValueError):
            validate_network_probe(direct, self.denied)

    def test_rejects_success_timeout_and_connection_refusal_as_block_evidence(self):
        for status in (0, 124, errno.ECONNREFUSED):
            with self.subTest(status=status), self.assertRaises(ValueError):
                validate_network_probe(self.connected, subprocess.CompletedProcess(
                    ["sandbox", "probe"], status, f"BLUEPRINT_LOOPBACK_ERRNO={status}\n".encode(), b"",
                ))

    def test_wrapper_exit_one_is_not_proof_that_the_child_was_run(self):
        failed_wrapper = subprocess.CompletedProcess(
            ["sandbox", "probe"], 1, b"", b"sandbox initialization failure\n",
        )
        with self.assertRaises(ValueError):
            validate_network_probe(self.connected, failed_wrapper)

    def test_requires_exact_independent_child_markers_and_empty_stderr(self):
        for direct, blocked in (
            (subprocess.CompletedProcess(["probe"], 0, b"", b""), self.denied),
            (self.connected, subprocess.CompletedProcess(["sandbox", "probe"], errno.EPERM, b"", b"")),
            (self.connected, subprocess.CompletedProcess(
                ["sandbox", "probe"], errno.EACCES, b"BLUEPRINT_LOOPBACK_ERRNO=1\n", b"",
            )),
            (self.connected, subprocess.CompletedProcess(
                ["sandbox", "probe"], errno.EPERM, b"BLUEPRINT_LOOPBACK_ERRNO=1\n", b"unexpected stderr\n",
            )),
        ):
            with self.subTest(direct=direct, blocked=blocked), self.assertRaises(ValueError):
                validate_network_probe(direct, blocked)
