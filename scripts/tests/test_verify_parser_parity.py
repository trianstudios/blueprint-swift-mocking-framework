from dataclasses import replace
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from verify_parser_parity import Case, Observation, normalize_diagnostic, qualify_cases, verify_receipt


SHARD = "BlueprintMocks.generated.swift"
INDEX = "BlueprintMockingIndex.generated.swift"
DIAGNOSTIC = b"Parent.swift:1:8: error: BPM001: Missing inherited protocol Root\n"
TYPED = Case("typed")
INHERITED = Case("inherited")
UNRESOLVED = Case("unresolved", diagnostic=DIAGNOSTIC)
SUCCESS = Observation(
    exit=0,
    stdout=b"Blueprint Mocking: generated 1 protocol mock(s)\n",
    stderr=b"",
    outputs={
        SHARD: b"enum BlueprintMockingShard_91a {}\n",
        INDEX: b"// SwiftPM input set: 91\n"
        b"enum BlueprintMockingGeneratedIndex { typealias Shard = BlueprintMockingShard_91a }\n"
        b"extension BlueprintMockingGeneratedIndex {\n"
        b"    static let irSchemaVersion: Swift.Int = 1\n"
        b"    static let runtimeContractVersion: Swift.Int = 1\n"
        b"}\n",
    },
)
REJECTION = Observation(exit=1, stdout=b"", stderr=DIAGNOSTIC, outputs={})
PROVENANCE = {"sourceRevision": "a" * 40}
STALE = b'{"status":"passed","sourceRevision":"stale"}\n'


class ParserParityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="Parser Parity Report ")
        self.addCleanup(directory.cleanup)
        self.report = Path(directory.name) / "parser-parity-report.json"

    def assert_rejected_without_success_report(self, case, bundled, packaged):
        self.report.write_bytes(STALE)
        calls = []

        def invoke(current, route):
            self.assertFalse(self.report.exists(), "success report is visible during qualification")
            calls.append((current.name, route))
            if current == TYPED:
                return SUCCESS
            return {"bundled": bundled, "packaged": packaged}[route]

        with self.assertRaises(ValueError):
            qualify_cases([TYPED, case], invoke, self.report, PROVENANCE)
        self.assertCountEqual(calls[:2], [(TYPED.name, "bundled"), (TYPED.name, "packaged")])
        self.assertFalse(self.report.exists())

    def test_writes_a_fresh_report_only_after_positive_and_negative_agree(self):
        self.report.write_bytes(STALE)
        calls = []

        def invoke(case, route):
            self.assertFalse(self.report.exists(), "success report is visible during qualification")
            calls.append((case.name, route))
            if case == UNRESOLVED:
                return replace(REJECTION, outputs=SUCCESS.outputs)
            return SUCCESS

        qualify_cases([TYPED, UNRESOLVED], invoke, self.report, PROVENANCE)

        self.assertCountEqual(calls, [
            (TYPED.name, "bundled"), (TYPED.name, "packaged"),
            (UNRESOLVED.name, "bundled"), (UNRESOLVED.name, "packaged"),
        ])
        self.assertTrue(self.report.is_file())
        self.assertNotEqual(self.report.read_bytes(), STALE)

    def test_removes_stale_report_after_generated_byte_mismatch(self):
        for name in (SHARD, INDEX):
            with self.subTest(output=name):
                modified = SUCCESS.outputs | {name: SUCCESS.outputs[name] + b"\n"}
                self.assert_rejected_without_success_report(
                    INHERITED, SUCCESS, replace(SUCCESS, outputs=modified),
                )

    def test_removes_stale_report_after_diagnostic_byte_mismatch(self):
        self.assert_rejected_without_success_report(
            UNRESOLVED, REJECTION, replace(REJECTION, stderr=DIAGNOSTIC.replace(b":1:8:", b":1:9:")),
        )

    def test_rejects_equal_positive_observations_without_exact_nonempty_outputs(self):
        for outputs in (
            {},
            {SHARD: SUCCESS.outputs[SHARD]},
            {INDEX: SUCCESS.outputs[INDEX]},
            SUCCESS.outputs | {"Unexpected.generated.swift": b"// unexpected\n"},
            SUCCESS.outputs | {SHARD: b""},
            SUCCESS.outputs | {INDEX: b""},
        ):
            with self.subTest(outputs=outputs):
                observation = replace(SUCCESS, outputs=outputs)
                self.assert_rejected_without_success_report(INHERITED, observation, observation)

    def test_rejects_positive_status_stderr_or_stdout_mismatch(self):
        for bundled, packaged in (
            (SUCCESS, replace(SUCCESS, exit=1)),
            (replace(SUCCESS, exit=2), replace(SUCCESS, exit=2)),
            (replace(SUCCESS, stderr=b"warning\n"), replace(SUCCESS, stderr=b"warning\n")),
            (SUCCESS, replace(SUCCESS, stdout=SUCCESS.stdout + b"\n")),
        ):
            with self.subTest(bundled=bundled, packaged=packaged):
                self.assert_rejected_without_success_report(INHERITED, bundled, packaged)

    def test_rejects_equal_negative_observations_with_unexpected_status_or_text(self):
        for observation in (
            replace(REJECTION, exit=2),
            replace(REJECTION, stdout=b"unexpected stdout\n"),
            replace(REJECTION, stderr=DIAGNOSTIC + b"\n"),
        ):
            with self.subTest(observation=observation):
                self.assert_rejected_without_success_report(UNRESOLVED, observation, observation)

    def test_rejects_negative_observations_with_different_preserved_output(self):
        self.assert_rejected_without_success_report(
            UNRESOLVED, REJECTION, replace(REJECTION, outputs=SUCCESS.outputs),
        )


class BuildReceiptTests(unittest.TestCase):
    def test_rejects_equivalent_boolean_schema_and_changed_executable_bytes(self):
        with tempfile.TemporaryDirectory(prefix="Parser Build Receipt ") as directory:
            root = Path(directory)
            executable = root / "generator"
            executable.write_bytes(b"original executable")
            receipt = root / "build.json"
            common = {"sourceRevision": "a" * 40}
            expected = common | {
                "schema": 1,
                "route": "bundled",
                "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            }
            receipt.write_text(json.dumps(expected))
            self.assertEqual(verify_receipt(receipt, common, "bundled", executable, {}), expected)
            receipt.write_text(json.dumps(expected | {"schema": True}))
            with self.assertRaises(ValueError):
                verify_receipt(receipt, common, "bundled", executable, {})
            receipt.write_text(json.dumps(expected))
            executable.write_bytes(b"different executable")
            with self.assertRaises(ValueError):
                verify_receipt(receipt, common, "bundled", executable, {})


class DiagnosticNormalizationTests(unittest.TestCase):
    def test_removes_observed_loader_trace_without_hiding_diagnostics(self):
        directory = Path("/private/tmp/Parser Parity Case")
        diagnostic = b"Parent.swift:1:8: error: BPM001: Missing inherited protocol Root\n"
        trace = (
            b"dyld[471]: <DEF2B2F1-4722-3B1A-A2DF-E65493BA1EA5> /Xcode/libSwiftSyntax.dylib\n"
            b"dyld[471]: move loaded to delayed: libCGInterfaces.dylib\n"
        )
        unexpected = b"dyld[471]: Library not loaded: /different/toolchain.dylib\n"
        stdout_lookalike = b"warning: dyld[471]: move loaded to delayed: retained text\n"
        full = trace + str(directory).encode() + b"/" + diagnostic + unexpected + stdout_lookalike
        self.assertEqual(normalize_diagnostic(full, directory), diagnostic + unexpected + stdout_lookalike)
