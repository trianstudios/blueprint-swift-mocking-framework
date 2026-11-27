import hashlib
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from verify_generation_performance import (
    benchmark, component_build_profile, make_corpus, output_state, parse_component_timing, parse_darwin_time,
    require_unchanged,
)

METER = b"""        0.15 real         0.10 user         0.02 sys
            10485760  maximum resident set size
                   3  page reclaims
"""


def fixture_output(directory, count=2, methods=1):
    directory.mkdir(exist_ok=True)
    templates = []
    for index in range(count):
        witnesses = "".join(f"    public func scaleMethod{method:02d}(_ input: Int) -> Int {{ input }}\n"
                            for method in range(methods))
        templates.append(f"public final class ScaleProtocol{index:04d}Mock: ScaleProtocol{index:04d} {{\n{witnesses}}}\n")
    (directory / "BlueprintMocks.generated.swift").write_text("".join(templates), encoding="utf-8")
    (directory / "BlueprintMockingIndex.generated.swift").write_text("enum BlueprintMockingGeneratedIndex {}\n",
                                                                   encoding="utf-8")


class GenerationPerformanceTests(unittest.TestCase):
    def test_mac_meter_requires_unique_metrics_and_separates_diagnostic(self):
        self.assertEqual(parse_darwin_time(METER), {
            "meterWallNanos": 150_000_000, "userCPUNanos": 100_000_000,
            "systemCPUNanos": 20_000_000, "peakResidentBytes": 10_485_760,
        })
        for bad in (b"0.15 real 0.10 user 0.02 sys\n", METER + b"4 maximum resident set size\n",
                    b"warning: unexpected\n" + METER, METER.replace(b"10485760", b"0")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parse_darwin_time(bad)

    def test_corpus_is_deterministic_bounded_and_counts_requirements(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, sources, profile = make_corpus(root / "source", 3, 2)
            self.assertEqual(profile["sourceProtocolDeclarations"], 3)
            self.assertEqual(profile["selectedRequirements"], 6)
            self.assertEqual(len(json.loads(config.read_bytes())["selections"]), 3)
            [source] = sources
            self.assertEqual(source.read_bytes().count(b"public protocol "), 3)
            self.assertEqual(source.read_bytes().count(b"    func "), 6)
            _, _, relocated_profile = make_corpus(root / "relocated", 3, 2)
            self.assertEqual(profile, relocated_profile)
            with self.assertRaises(ValueError):
                make_corpus(root / "oversized", 1001, 10)

    def test_generated_counts_and_mtime_guard(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture_output(root, 2, 2)
            captured = output_state(root, 2, 2)
            with self.assertRaisesRegex(ValueError, "witness"):
                output_state(root, 2, 3)
            changed = root / "BlueprintMockingIndex.generated.swift"
            metadata = changed.stat()
            os.utime(changed, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 3_000_000_000))
            with self.assertRaisesRegex(ValueError, "no-op"):
                require_unchanged(root, captured)
            body = changed.read_bytes()
            changed.write_bytes(body.replace(b"Index", b"Indey"))
            os.utime(changed, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            with self.assertRaisesRegex(ValueError, "no-op"):
                require_unchanged(root, captured)

    def test_full_control_sequence_and_no_certification_from_synthetic_samples(self):
        observed = []

        def fake_tool(tool, root, configuration, output, sources, evidence, label, environment, count):
            state = "absent" if not output.exists() else "populated" if list(output.iterdir()) else "empty"
            observed.append((label, state))
            if state != "populated":
                fixture_output(output, count, 2 if label == "cold" else 1)
            return {"processWallNanos": 400, "peakResidentBytes": 1000}

        with TemporaryDirectory() as temporary:
            result = benchmark(Path("/fake-tool"), Path(temporary), {}, 2, 2, 2, invoke=fake_tool)
        self.assertEqual(observed, [
            ("cold", "absent"), ("warm-seed", "empty"), ("warm-1", "populated"), ("warm-2", "populated"),
        ])
        self.assertIsNone(result["certificationVerdict"])
        self.assertIsNone(result["warm"]["launchExcludedMedianNanos"])
        self.assertEqual(result["warm"]["medianProcessWallNanos"], 400)

class ComponentTimingTests(unittest.TestCase):
    nonce = "ff" * 16

    def line(self, entry=20, start=25, end=50, nonce=None):
        return f"DX032_GENERATION_TIME_V1 {nonce or self.nonce} {entry} {start} {end}\n".encode("ascii")

    def test_direct_boundaries_keep_process_meter_separate(self):
        meter, times = parse_component_timing(self.line() + METER, self.nonce, 10, 60)
        self.assertEqual(meter, METER)
        self.assertEqual(times, {
            "launchToSwiftEntryNanos": 10, "argumentDispatchNanos": 5,
            "configuredGenerationNanos": 25, "afterSwiftEntryNanos": 30,
            "completionToExitNanos": 10,
        })

    def test_refuses_stale_duplicate_wrong_nonce_and_impossible_measurements(self):
        cases = (
            (self.line(entry=9), "clock"),
            (self.line() + self.line(), "exactly one"),
            (self.line(nonce="aa" * 16), "nonce"),
            (self.line(start=19), "clock"),
            (self.line(end=25), "clock"),
            (self.line(end=61), "clock"),
            (self.line(start="false"), "integer"),
            (b"", "exactly one"),
        )
        for prefix, message in cases:
            with self.subTest(prefix=prefix), self.assertRaisesRegex(ValueError, message):
                parse_component_timing(prefix + METER, self.nonce, 10, 60)

    def test_timed_fixture_reports_direct_steady_generation_with_null_verdict(self):
        def fake_tool(tool, root, configuration, output, sources, evidence, label, environment, count):
            state = "absent" if not output.exists() else "populated" if list(output.iterdir()) else "empty"
            if state != "populated":
                fixture_output(output, count, 2 if label == "cold" else 1)
            _, times = parse_component_timing(self.line() + METER, self.nonce, 10, 60)
            return {"processWallNanos": 50, "peakResidentBytes": 1000, "componentTiming": times}

        with TemporaryDirectory() as temporary:
            result = benchmark(Path("/fake-tool"), Path(temporary), {}, 2, 2, 2, invoke=fake_tool)
        self.assertEqual(result["warm"]["medianProcessWallNanos"], 50)
        self.assertEqual(result["warm"]["launchExcludedMedianNanos"], 30)
        self.assertEqual(result["warm"]["configuredGenerationMedianNanos"], 25)
        self.assertEqual(result["toolLaunchNanos"], 10)
        self.assertIsNone(result["certificationVerdict"])

    def test_build_meter_receipt_and_exact_archive_are_bound(self):
        revision = "f" * 40
        receipt = "a" * 64
        compiler = "/prepared/Xcode/swiftc"
        artifacts = {
            "buildCommandSHA256": ("build.command", f"{compiler} -Onone -D BLUEPRINT_MEASURE_GENERATION\n".encode()),
            "buildMeterSHA256": ("build.meter-stderr", METER),
            "linkageSHA256": ("bundled-linkage.log", b"parser link evidence"),
            "sourceArchiveSHA256": ("source.tar", b"archive bytes"),
        }
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = {"bundledReceiptSHA256": receipt, "buildOptimization": "-Onone"}
            for name, (filename, data) in artifacts.items():
                (root / filename).write_bytes(data)
                profile[name] = hashlib.sha256(data).hexdigest()
            metadata = root / "build-provenance.json"
            metadata.write_text(json.dumps(profile), encoding="utf-8")
            with patch("verify_generation_performance.subprocess.check_output", return_value=revision):
                accepted = component_build_profile(root, receipt, revision, {"SWIFT_EXEC": compiler})
                self.assertEqual(accepted["meter"]["meterWallNanos"], 150_000_000)
                with self.assertRaisesRegex(ValueError, "artifacts"):
                    component_build_profile(root, "b" * 64, revision, {"SWIFT_EXEC": compiler})
            with patch("verify_generation_performance.subprocess.check_output", return_value="e" * 40):
                with self.assertRaisesRegex(ValueError, "archive revision"):
                    component_build_profile(root, receipt, revision, {"SWIFT_EXEC": compiler})
            (root / "build.meter-stderr").write_bytes(METER + b"changed")
            with self.assertRaisesRegex(ValueError, "artifacts"):
                component_build_profile(root, receipt, revision, {"SWIFT_EXEC": compiler})
