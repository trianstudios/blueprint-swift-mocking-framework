#!/usr/bin/env python3
"""Exercise verified tooling installation and rejected archives through the public CLI."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

from export_tooling import PROVENANCE, build_archive, git, verify_archive
from verify_inspection import snapshot
from verify_remote_install import validate_revision


REPORT = "tooling-install-report.json"
TARGET = "Sources/BlueprintMockingCLI/main.swift"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def altered_archive(contents):
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:") as archive:
        files = {entry.name: archive.extractfile(entry).read() for entry in archive}
    files[TARGET] = b"// Altered source for the tooling archive consumer fixture.\n" + files[TARGET]
    manifest = json.loads(files[PROVENANCE])
    entry, = [entry for entry in manifest["files"] if entry["path"] == TARGET]
    entry["sha256"] = digest(files[TARGET])
    files[PROVENANCE] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in sorted(files.items()):
            entry = tarfile.TarInfo(name)
            entry.mode = 0o644
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    return result.getvalue()


def verify(repository, revision, mirror, evidence):
    validate_revision(revision)
    valid = build_archive(repository, revision)
    earlier = git(repository, "rev-parse", f"{revision}^").decode("ascii").strip()
    substituted = build_archive(repository, earlier)
    current_info = verify_archive(valid, repository, revision)
    earlier_info = verify_archive(substituted, repository, earlier)
    installed = evidence / "verified-tooling-install"
    artifacts = {}

    with tempfile.TemporaryDirectory(prefix="Tooling Archive Boundary ", dir=evidence) as temporary:
        scratch = Path(temporary)
        archive = scratch / "tooling.tar"

        def run(label, contents, destination, environment=None):
            archive.write_bytes(contents)
            command = [sys.executable, str(repository / "scripts/verify_tooling_install.py"), revision,
                       "--repository", str(repository), "--archive", str(archive),
                       "--swift-syntax-mirror", str(mirror), "--evidence-dir", str(destination)]
            result = subprocess.run(command, env=environment, capture_output=True, timeout=90)
            log = evidence / f"tooling-archive-{label}.log"
            log.write_bytes(result.stdout + result.stderr)
            artifacts[log.name] = digest(log.read_bytes())
            return result, log

        accepted, log = run("valid", valid, installed)
        if (accepted.returncode != 0 or accepted.stderr
                or b"PASS: resolved tooling exposes the executable and SwiftPM build plugin" not in accepted.stdout
                or b"PASS: installed tooling checkout matches every verified archive file" not in accepted.stdout):
            raise ValueError(f"The valid archive did not resolve from its fresh extraction. See {log}")
        report_bytes = (installed / REPORT).read_bytes()
        install_report = json.loads(report_bytes)
        if (install_report["sourceRevision"] != revision or install_report["archiveSHA256"] != digest(valid)
                or install_report["swiftSyntax"] != current_info["compatibility"]["swiftSyntax"]):
            raise ValueError("The installed archive evidence does not match its prepared input")
        with tarfile.open(fileobj=io.BytesIO(valid), mode="r:") as verified_tar:
            expected_files = {entry.name: digest(verified_tar.extractfile(entry).read()) for entry in verified_tar}
        observed_files = json.loads((installed / "tooling-install-extracted-files.json").read_bytes())
        if observed_files != expected_files:
            raise ValueError("The independent checkout file inventory does not match the verified archive")
        artifacts[f"{installed.name}/{REPORT}"] = digest(report_bytes)
        for name, expected in install_report["artifacts"].items():
            if digest((installed / name).read_bytes()) != expected:
                raise ValueError(f"The installer did not preserve evidence artifact {name}")
            artifacts[f"{installed.name}/{name}"] = expected

        # A rejection must occur before the installer even asks for a Swift driver.
        trap = scratch / "Toolchain Trap"
        trap.mkdir()
        marker = scratch / "toolchain-started"
        xcrun = trap / "xcrun"
        xcrun.write_text('#!/bin/sh\nprintf "started\\n" > "$BLUEPRINT_ARCHIVE_TOOLCHAIN_MARKER"\nexit 79\n')
        xcrun.chmod(0o700)
        environment = os.environ | {"PATH": str(trap) + os.pathsep + os.environ["PATH"],
                                    "BLUEPRINT_ARCHIVE_TOOLCHAIN_MARKER": str(marker)}
        before = snapshot(installed)
        negatives = {}
        for label, data in (("tampered", altered_archive(valid)), ("substituted", substituted)):
            result, log = run(label, data, installed, environment)
            expected = f"Tooling install verification failed: Archive does not match the committed tooling export for {revision}\n"
            if (result.returncode != 1 or result.stdout or result.stderr != expected.encode("utf-8")
                    or marker.exists() or snapshot(installed) != before):
                raise ValueError(f"{label} archive did not fail before toolchain selection and evidence changes. See {log}")
            negatives[label] = {"archiveSHA256": digest(data), "exit": result.returncode,
                                "priorEvidencePreserved": True}

    report = {
        "sourceRevision": revision,
        "validArchiveSHA256": digest(valid),
        "gitTransport": "file-only",
        "substitutedSourceRevision": earlier,
        "substitutedPayloadMatches": current_info["files"] == earlier_info["files"],
        "rejections": negatives,
        "artifacts": artifacts,
    }
    path = evidence / "tooling-archive-consumer-report.json"
    path.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: verified tooling archive resolved from a fresh extraction using the prepared mirror")
    print("PASS: tampered and substituted archives rejected before toolchain selection with prior evidence preserved")
    print(f"EVIDENCE: {path.name} SHA-256 {digest(path.read_bytes())}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision")
    parser.add_argument("--swift-syntax-mirror", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    options = parser.parse_args()
    try:
        if sys.platform != "darwin":
            raise ValueError("The archive consumer's toolchain-start control requires macOS")
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "tooling-archive-consumer-report.json").unlink(missing_ok=True)
        verify(options.repository.resolve(strict=True), options.revision,
               options.swift_syntax_mirror.resolve(strict=True), evidence)
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Tooling archive consumer qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
