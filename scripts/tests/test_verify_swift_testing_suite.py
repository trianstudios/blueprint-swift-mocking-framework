import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify import swift_testing_suite_proof


AGGREGATE = r"\b[1-9]\d* tests?\b.*\bpassed\b"
NAMED = r"requiredTest\(\) passed"
OUTPUT = r"fixture receipt"
TEST = "ConsumerTests.requiredTest()/Fixture.swift:1:1"


class SwiftTestingSuiteProofTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.events = Path(directory.name, "suite.jsonl")
        self.payloads = [
            {"kind": "runStarted"},
            {"kind": "testStarted", "testID": TEST},
            {"kind": "testEnded", "testID": TEST},
            {"kind": "runEnded", "messages": [{"symbol": "pass", "text": "Test run with 1 test passed."}]},
        ]

    def proof(self, output="fixture receipt"):
        self.events.write_text("".join(json.dumps({"version": 0, "kind": "event", "payload": event}) + "\n"
                                       for event in self.payloads), encoding="utf-8")
        return swift_testing_suite_proof(self.events, [AGGREGATE, NAMED, OUTPUT], output)

    def test_proof_recovers_native_completion_without_console_pass_line(self):
        summary, count, digest = self.proof()
        self.assertEqual((summary, count), ("Test run with 1 test passed.", 1))
        self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_console_completion_cannot_replace_missing_native_event(self):
        self.payloads[2:3] = []
        with self.assertRaisesRegex(ValueError, "completion"):
            self.proof("fixture receipt\nrequiredTest() passed")

    def test_unknown_issue_prevents_success_even_with_pass_summary(self):
        self.payloads.insert(2, {"kind": "issueRecorded", "issue": {"isKnown": False}})
        with self.assertRaisesRegex(ValueError, "unexpected issue"):
            self.proof()

    def test_summary_must_match_native_completion_count(self):
        self.payloads[-1]["messages"][0]["text"] = "Test run with 2 tests passed."
        with self.assertRaisesRegex(ValueError, "completion count"):
            self.proof()

    def test_non_test_console_requirement_is_still_enforced(self):
        with self.assertRaisesRegex(ValueError, "fixture receipt"):
            self.proof("")


if __name__ == "__main__":
    unittest.main()
