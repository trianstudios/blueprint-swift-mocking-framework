import sys
import unittest
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from verify_runtime_performance import (
    clean_revision, summarize, validate_dependencies, validate_release_compilation, validate_sample,
)


def sample(mode="latency"):
    count = {"latency": 10_000, "admission": 100_000, "retirement": 2_000}[mode]
    row = {
        "mode": mode, "calls": count, "workers": 8 if mode == "admission" else 1,
        "heapBefore": {"liveBlocks": 100, "liveBytes": 4_096},
        "heapAfter": {"liveBlocks": 120, "liveBytes": 8_192},
        "peakResidentBytes": 32768,
    }
    if mode == "retirement":
        return row | {
            "releasedBeforeReset": 0, "releasedAfterReset": count,
            "resetNanos": 30_000, "finishNanos": 10_000,
            "heapAfterReset": {"liveBlocks": 98, "liveBytes": 4_080},
            "activeAfterFinish": 0, "eventsAfterFinish": 0, "finished": True,
        }
    row["durationNanos"] = 50_000_000
    row["history"] = {
        "admissions": count, "returns": count, "uniqueAdmissions": count,
        "uniqueReturns": count, "identitySetsMatch": True, "epochMatches": True,
        "unpruned": True, "active": 0, "typedReturnedMatches": count,
    }
    if mode == "latency":
        row["warmupCalls"] = 2_000
        row["percentilesNanos"] = {"p50": 1000, "p95": 2200, "p99": 3000}
    return row


class SampleValidationTests(unittest.TestCase):
    def test_nominal_samples(self):
        for mode in ("latency", "admission", "retirement"):
            self.assertEqual(validate_sample(mode, sample(mode)), sample(mode))

    def test_exact_concurrent_fixture_shape(self):
        measurement = sample("admission")
        measurement["workers"] = 7
        with self.assertRaisesRegex(ValueError, "workers"):
            validate_sample("admission", measurement)

    def test_rejects_lost_duplicate_and_wrong_epoch_evidence(self):
        for field, value in (
            ("admissions", 99_999), ("uniqueReturns", 99_999), ("epochMatches", False),
            ("identitySetsMatch", False), ("active", 1), ("unpruned", False),
            ("typedReturnedMatches", 0),
        ):
            with self.subTest(field=field):
                measurement = sample("admission")
                measurement["history"][field] = value
                with self.assertRaisesRegex(ValueError, field):
                    validate_sample("admission", measurement)

    def test_rejects_nonnumeric_or_nonmonotonic_percentiles(self):
        for value in (False, -1, 9000):
            measurement = sample()
            measurement["percentilesNanos"]["p50"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "percentile"):
                validate_sample("latency", measurement)

    def test_rejects_missing_release_and_unfinished_teardown(self):
        for field, value in (
            ("releasedBeforeReset", 1), ("releasedAfterReset", 1999),
            ("finished", False), ("eventsAfterFinish", 1),
        ):
            measurement = sample("retirement")
            measurement[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, field):
                validate_sample("retirement", measurement)

    def test_rejects_bool_and_missing_heap_metric(self):
        measurement = sample("retirement")
        measurement["heapAfterReset"]["liveBlocks"] = True
        with self.assertRaisesRegex(ValueError, "liveBlocks"):
            validate_sample("retirement", measurement)
        measurement = sample()
        del measurement["heapAfter"]["liveBytes"]
        with self.assertRaisesRegex(ValueError, "liveBytes"):
            validate_sample("latency", measurement)

    def test_observed_targets_do_not_certify_an_unattributed_archive(self):
        fast = sample()
        slow = deepcopy(fast)
        slow["percentilesNanos"]["p50"] = 2150
        summary = summarize({"latency": [fast, slow], "admission": [sample("admission")],
                             "retirement": [sample("retirement")]})
        self.assertEqual(summary["absoluteMedianLatencyTargetNanos"], 2_000)
        self.assertEqual(summary["samplesAtOrBelowLatencyTarget"], 1)
        self.assertIsNone(summary["regressionVerdict"])
        self.assertIsNone(summary["certificationVerdict"])
        self.assertEqual(summary["admission"][0]["netLiveBytes"], 4096)
        self.assertEqual(summary["retirement"][0]["netLiveBytesAfterReset"], -16)


class BuildProvenanceTests(unittest.TestCase):
    def test_release_logs_require_actual_compiler_jobs_for_both_targets(self):
        records = (
            "/Xcode/Toolchain/usr/bin/swiftc -module-name BlueprintMocking -O -emit-module -whole-module-optimization\n"
            "/Xcode/Toolchain/usr/bin/swiftc -module-name RuntimePerformanceProbe -O -emit-module -whole-module-optimization"
        )
        validate_release_compilation(records)
        with self.assertRaisesRegex(ValueError, "BlueprintMocking"):
            validate_release_compilation(records.replace("BlueprintMocking -O", "BlueprintMocking -Onone"))
        with self.assertRaisesRegex(ValueError, "RuntimePerformanceProbe"):
            validate_release_compilation(records.splitlines()[0])
        with self.assertRaisesRegex(ValueError, "BlueprintMocking"):
            validate_release_compilation("echo " + records)

    def test_dependency_graph_must_be_exact_local_core_checkout(self):
        with TemporaryDirectory() as directory:
            local = Path(directory)
            graph = {"dependencies": [{"path": str(local), "dependencies": []}]}
            validate_dependencies(graph, local)
            with self.assertRaisesRegex(ValueError, "dependency graph"):
                validate_dependencies([], local)
            with self.assertRaisesRegex(ValueError, "runtime path"):
                validate_dependencies({"dependencies": ["malformed"]}, local)
            with self.assertRaisesRegex(ValueError, "runtime path"):
                validate_dependencies(graph, local / "replacement")
            with self.assertRaisesRegex(ValueError, "no transitive"):
                validate_dependencies({"dependencies": [{"path": str(local), "dependencies": [{}]}]}, local)
            with self.assertRaisesRegex(ValueError, "one dependency"):
                validate_dependencies({"dependencies": []}, local)

    def test_clean_revision_rejects_dirty_edits_and_wrong_repository_root(self):
        revision = "a" * 40
        root = Path("/checkout")
        with patch("verify_runtime_performance.git_text", side_effect=[str(root), revision, ""]):
            self.assertEqual(clean_revision(root, {}), revision)
        with patch("verify_runtime_performance.git_text", side_effect=[str(root), revision, "?? unexpected.swift"]):
            with self.assertRaisesRegex(ValueError, "clean checkout"):
                clean_revision(root, {})
        with patch("verify_runtime_performance.git_text", return_value="/different"):
            with self.assertRaisesRegex(ValueError, "Git root"):
                clean_revision(root, {})


if __name__ == "__main__":
    unittest.main()
