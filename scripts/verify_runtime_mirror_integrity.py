#!/usr/bin/env python3
"""Exercise a corrupted Git object at the offline runtime consumer boundary."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zlib

from verify_offline_runtime import offline_git_environment
from verify_remote_install import validate_revision


REPOSITORY = Path(__file__).resolve().parents[1]
REPORT = "runtime-only-offline-report.json"
CORRUPTION_LOG = "runtime-mirror-corruption-consumer.log"


def git(repository, environment, *arguments, input_data=None):
    return subprocess.run(
        ["git", "-C", str(repository), *arguments], env=environment,
        input=input_data, capture_output=True, check=True, timeout=60,
    ).stdout


def verify(revision, repository, mirror, evidence, valid_report):
    validate_revision(revision)
    previous = valid_report.read_bytes()
    if json.loads(previous)["sourceRevision"] != revision:
        raise ValueError("The valid offline run must use the same revision as the corruption fixture")
    environment = offline_git_environment(os.environ)
    with tempfile.TemporaryDirectory(prefix="Runtime Mirror Integrity ", dir=evidence) as temporary:
        scratch = Path(temporary)
        corrupt = scratch / "corrupt.git"
        corrupt.mkdir()
        git(corrupt, environment, "init", "--bare", "--quiet", "--template=", "--initial-branch=main")
        pack = git(mirror, environment, "pack-objects", "--stdout", "--revs", input_data=f"{revision}\n".encode())
        git(corrupt, environment, "unpack-objects", "-q", input_data=pack)
        git(corrupt, environment, "update-ref", "refs/heads/main", revision)

        blob = git(corrupt, environment, "rev-parse", f"{revision}:Package.swift").decode("ascii").strip()
        original = git(corrupt, environment, "cat-file", "blob", blob)
        changed = original + b"\n// Altered bytes for the DX-020 corruption fixture.\n"
        raw = f"blob {len(changed)}\0".encode("ascii") + changed
        object_name = f"objects/{blob[:2]}/{blob[2:]}"
        object_path = corrupt / object_name
        replacement = scratch / "replacement"
        replacement.write_bytes(zlib.compress(raw))
        replacement.replace(object_path)
        if (git(corrupt, environment, "cat-file", "-t", revision) != b"commit\n"
                or git(corrupt, environment, "rev-parse", f"{revision}:Package.swift").strip() != blob.encode("ascii")
                or git(corrupt, environment, "cat-file", "blob", blob) != changed):
            raise ValueError("The corruption fixture must retain the commit pin and expose the altered blob")

        output = scratch / "Existing Consumer Evidence"
        output.mkdir()
        existing = output / REPORT
        existing.write_bytes(previous)
        timestamp = existing.stat().st_mtime_ns
        result = subprocess.run(
            [sys.executable, str(repository / "scripts/verify_offline_runtime.py"), revision,
             "--runtime-mirror", str(corrupt), "--repository", str(repository), "--evidence-dir", str(output)],
            capture_output=True, env=environment, timeout=120,
        )
        log = evidence / CORRUPTION_LOG
        log.write_bytes(result.stdout + result.stderr)
        if (result.returncode != 1 or result.stdout
                or b"Runtime mirror failed Git object integrity check" not in result.stderr
                or b"hash-path mismatch" not in result.stderr
                or not any(identifier.encode("ascii") in result.stderr for identifier in (blob, object_name))):
            raise ValueError(f"The pinned corrupt mirror was not rejected at the Git integrity gate. See {log}")
        if (set(output.iterdir()) != {existing} or existing.read_bytes() != previous
                or existing.stat().st_mtime_ns != timestamp):
            raise ValueError("Corrupt mirror rejection modified the previous offline consumer evidence")

        report = {
            "sourceRevision": revision,
            "retainedBlobID": blob,
            "validReportSHA256": hashlib.sha256(previous).hexdigest(),
            "originalManifestSHA256": hashlib.sha256(original).hexdigest(),
            "alteredManifestSHA256": hashlib.sha256(changed).hexdigest(),
            "exit": result.returncode,
            "priorEvidencePreserved": True,
            "artifacts": {log.name: hashlib.sha256(log.read_bytes()).hexdigest()},
        }
    path = evidence / "runtime-mirror-corruption-report.json"
    path.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: pinned corrupt runtime mirror rejected before SwiftPM consumption and prior evidence preserved")
    print(f"EVIDENCE: {path.name} SHA-256 {hashlib.sha256(path.read_bytes()).hexdigest()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision")
    parser.add_argument("--runtime-mirror", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--valid-report", required=True, type=Path)
    parser.add_argument("--repository", type=Path, default=REPOSITORY)
    options = parser.parse_args()
    try:
        evidence = options.evidence_dir.resolve(strict=True)
        verify(options.revision, options.repository.resolve(strict=True), options.runtime_mirror.resolve(strict=True),
               evidence, options.valid_report.resolve(strict=True))
        return 0
    except (OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"Runtime mirror corruption fixture failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
