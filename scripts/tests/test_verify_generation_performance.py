import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from verify_generation_performance import (
    benchmark, make_corpus, output_state, parse_darwin_time, require_unchanged,
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
