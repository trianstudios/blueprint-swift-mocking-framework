#!/usr/bin/env python3
"""Check the release acceptance registry and, where available, certification artifacts.

Exit 0: ready (or a valid report with --report-only).
Exit 1: valid but incomplete release registry.
Exit 2: invalid registry or unsupported completion claim.

The optional --certification JSON is a reviewed release-plan input. A schema-1
object contains revision (full Git hash), profiles (map of IDs to exact compiler
and platform metadata), and contracts (map of feature IDs to acceptance_gate,
required_profiles, and evidence). Evidence maps each required profile ID to an
artifact file relative to the plan directory and its SHA-256 (file, sha256).
Each evidence artifact is a schema-1 object binding feature_id, acceptance_gate,
revision, profile (the full metadata object), and results. Results use the
verify.py check, passed, exit, and expected_failure fields.

A Complete row needs implementation references and named checks, separated by
semicolons. Reference paths are relative to the repository. Each required
profile must pass every named check, including a diagnostic check's intended
nonzero exit when expected_failure is true. Profiles record exact toolchain,
host, SDK, target, isolation, feature flags, and runner. A capability unavailable
on a profile needs its documented boundary evidence.

Reviewers determine which profiles and checks satisfy the textual acceptance
gate. The checker validates consistency and artifact integrity against that
reviewed input. It does not run tests or authenticate the producer.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re
import sys


REPO = Path(__file__).resolve().parent.parent
EXPECTED_IDS = {
    f"{family}-{number:03}"
    for family, total in (("SYS", 9), ("GEN", 40), ("RUN", 42), ("DX", 34))
    for number in range(1, total + 1)
}
STATES = ("Unimplemented", "Partial", "Complete")
REQUIRED_COLUMNS = {
    "Feature ID", "Acceptance gate", "Implementation status",
    "Implementation references", "Evidence checks",
}
PROFILE_FIELDS = {
    "compiler", "swift_syntax", "host_os", "host_arch", "sdk", "target",
    "language_mode", "default_isolation", "test_runner",
}


def read_registry(path):
    errors = []
    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream, strict=True)
        columns = reader.fieldnames or []
        missing = REQUIRED_COLUMNS.difference(columns)
        if missing or len(columns) != len(set(columns)):
            raise ValueError("registry has missing or duplicate columns: " + ", ".join(sorted(missing)))
        rows = list(reader)

    ids = Counter(row.get("Feature ID") for row in rows)
    for feature in sorted(EXPECTED_IDS.difference(ids)):
        errors.append(f"missing feature ID {feature}")
    for feature in sorted(set(ids).difference(EXPECTED_IDS), key=str):
        errors.append(f"unexpected feature ID {feature!r}")
    for feature, count in sorted(ids.items(), key=lambda entry: str(entry[0])):
        if count > 1:
            errors.append(f"duplicate feature ID {feature!r}")

    accepted = {}
    for row in rows:
        feature = row.get("Feature ID")
        if None in row or any(value is None for value in row.values()):
            errors.append(f"{feature!r}: malformed CSV row")
            continue
        if row["Implementation status"] not in STATES:
            errors.append(f"{feature!r}: unknown status {row['Implementation status']!r}")
            continue
        if not row["Acceptance gate"].strip():
            errors.append(f"{feature!r}: missing acceptance gate")
            continue
        if feature in EXPECTED_IDS and ids[feature] == 1:
            accepted[feature] = row
    return accepted, errors


def nonempty(text):
    return isinstance(text, str) and bool(text.strip())


def obj(data, label):
    if not isinstance(data, dict):
        raise ValueError(f"{label} must be a JSON object")
    return data


def read_json(data, label):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"{label} has a duplicate key {key!r}")
            result[key] = value
        return result

    return obj(json.loads(data, object_pairs_hook=unique_pairs), label)


def validate_header(document, revision):
    if type(document.get("schema")) is not int or document["schema"] != 1:
        raise ValueError("unsupported evidence schema")
    if document.get("revision") != revision:
        raise ValueError("evidence revision does not match the requested release revision")


def load_plan(path, revision):
    if not isinstance(revision, str) or not re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", revision):
        raise ValueError("--revision must be a full Git hash when a certification plan is supplied")
    plan = read_json(path.read_bytes(), "certification plan")
    validate_header(plan, revision)
    profiles = obj(plan.get("profiles"), "profiles")
    for profile_id, profile in profiles.items():
        obj(profile, f"profile {profile_id}")
        flags = profile.get("feature_flags")
        if (not nonempty(profile_id)
                or any(not nonempty(profile.get(field)) for field in PROFILE_FIELDS)
                or profile["language_mode"] != "6"
                or not isinstance(flags, list)
                or not all(nonempty(flag) for flag in flags)):
            raise ValueError(f"profile {profile_id!r} is missing exact Swift 6 platform metadata")
    contracts = obj(plan.get("contracts"), "contracts")
    unknown = set(contracts).difference(EXPECTED_IDS)
    if unknown:
        raise ValueError("plan has unexpected feature IDs: " + ", ".join(sorted(unknown)))
    return profiles, contracts


def field_values(field):
    return [value.strip() for value in field.split(";") if value.strip()]


def contained_path(root, name):
    if not nonempty(name):
        raise ValueError("missing relative file path")
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"path must stay inside {root.name}: {name!r}")
    path = (root / relative).resolve()
    if not path.is_relative_to(root) or not path.exists():
        raise ValueError(f"path is missing or outside {root.name}: {name!r}")
    return path


def check_artifact(directory, entry, feature, gate, revision, profile, checks):
    entry = obj(entry, "evidence entry")
    path = contained_path(directory, entry.get("file"))
    artifact_bytes = path.read_bytes()
    if hashlib.sha256(artifact_bytes).hexdigest() != entry.get("sha256"):
        raise ValueError("artifact SHA-256 does not match the certification plan")
    report = read_json(artifact_bytes, "evidence artifact")
    validate_header(report, revision)
    if report.get("feature_id") != feature or report.get("acceptance_gate") != gate:
        raise ValueError("artifact does not match the contract and acceptance gate")
    if report.get("profile") != profile:
        raise ValueError("artifact does not match the required profile")

    results = report.get("results")
    if not isinstance(results, list):
        raise ValueError("evidence artifact needs check results")
    observed = set()
    for result in results:
        result = obj(result, "check result")
        name = result.get("check")
        status = result.get("exit")
        negative = result.get("expected_failure")
        if not nonempty(name) or name in observed:
            raise ValueError(f"missing or duplicate check result: {name!r}")
        if (result.get("passed") is not True or type(status) is not int
                or type(negative) is not bool or (status != 0) != negative):
            raise ValueError(f"check {name!r} lacks a passing result with its expected exit")
        observed.add(name)
    missing = set(checks).difference(observed)
    if missing:
        raise ValueError("artifact is missing checks: " + ", ".join(sorted(missing)))


def certify(row, directory, plan, revision):
    feature = row["Feature ID"]
    gate = row["Acceptance gate"]
    references = field_values(row["Implementation references"])
    checks = field_values(row["Evidence checks"])
    if not references or not checks or len(checks) != len(set(checks)):
        raise ValueError("completed contract needs implementation references and unique evidence checks")
    for reference in references:
        contained_path(REPO, reference)

    profiles, contracts = plan
    claim = obj(contracts.get(feature), "completed contract certification entry")
    if claim.get("acceptance_gate") != gate:
        raise ValueError("certification plan does not match the acceptance gate")
    required = claim.get("required_profiles")
    if (not isinstance(required, list) or not required or not all(nonempty(item) for item in required)
            or len(required) != len(set(required)) or any(profile not in profiles for profile in required)):
        raise ValueError("completed contract must list available, unique required profiles")
    evidence = obj(claim.get("evidence"), "evidence")
    if set(required) != set(evidence):
        raise ValueError("evidence must cover each required profile exactly once")
    for profile_id in sorted(required):
        try:
            check_artifact(directory, evidence[profile_id], feature, gate, revision,
                           profiles[profile_id], checks)
        except (OSError, ValueError) as error:
            raise ValueError(f"profile {profile_id}: {error}") from error


def evaluate(registry, certification=None, revision=None):
    counts = {"certified": 0, "partial": 0, "unimplemented": 0}
    errors = []
    pending = []
    try:
        rows, errors = read_registry(registry)
    except (OSError, ValueError, csv.Error) as error:
        rows = {}
        errors.append(str(error))
    plan = None
    if certification:
        try:
            plan = load_plan(certification, revision)
        except (OSError, ValueError) as error:
            errors.append(str(error))
    for feature, row in sorted(rows.items()):
        status = row["Implementation status"]
        if status != "Complete":
            counts[status.lower()] += 1
            pending.append(feature)
            continue
        if plan is None:
            errors.append(f"{feature}: completed contract requires a valid certification plan and revision")
            continue
        try:
            certify(row, certification.resolve().parent, plan, revision)
            counts["certified"] += 1
        except (OSError, ValueError) as error:
            errors.append(f"{feature}: {error}")

    state = "invalid" if errors else ("incomplete" if pending else "ready")
    return {
        "state": state, "total": len(EXPECTED_IDS), "counts": counts,
        "pending": pending, "errors": sorted(errors),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--registry", type=Path, default=REPO / "Docs" / "Acceptance-Status.csv")
    parser.add_argument("--certification", type=Path, help="reviewed schema-1 release plan and artifact index")
    parser.add_argument("--revision", help="full Git hash for the release evidence being evaluated")
    parser.add_argument("--json", action="store_true", help="emit a deterministic machine-readable report")
    parser.add_argument("--report-only", action="store_true", help="allow an incomplete but valid registry")
    args = parser.parse_args()
    result = evaluate(args.registry, args.certification, args.revision)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"Release readiness: {result['state'].upper()}")
        counts = result["counts"]
        print(f"{counts['certified']}/{result['total']} certified, "
              f"{counts['partial']} partial, {counts['unimplemented']} unimplemented.")
        for error in result["errors"]:
            print(f"Error: {error}")
    return {"invalid": 2, "incomplete": 0 if args.report_only else 1, "ready": 0}[result["state"]]


if __name__ == "__main__":
    sys.exit(main())
