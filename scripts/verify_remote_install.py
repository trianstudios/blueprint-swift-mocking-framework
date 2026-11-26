#!/usr/bin/env python3
"""Verify installed consumers at a GitHub revision or exact release version."""

import argparse
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


REMOTE_URL = "https://github.com/trianstudios/blueprint-swift-mocking-framework.git"
PACKAGE_ID = "blueprint-swift-mocking-framework"
LOCAL_NAME = "BluepringMockingFramework"
LOCAL_DEPENDENCY = f'.package(name: "{LOCAL_NAME}", path: "../..")'
FIXTURES = {
    "RuntimeOnly": (["run", "RuntimeOnly"], r"PASS: runtime-only consumer"),
    "ProtocolConsumer": (
        ["test", "--disable-xctest"], r"Test run with [1-9][0-9]* tests?\b.*\bpassed\b",
    ),
    "XCTestConsumer": (
        ["test", "--disable-swift-testing"], r"Test Case .*testPassingVerificationDoesNotRecordAnIssue.* passed",
    ),
}
SEMVER = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def validate_revision(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("the resolved Git revision must be a full 40-character commit SHA")


def validate_version(version):
    match = SEMVER.fullmatch(version)
    if not match:
        raise ValueError("expected an exact SemVer version, for example 1.2.3 or 1.2.3-rc.1")
    prerelease = match.group(1)
    if prerelease and any(
        part.isdecimal() and len(part) > 1 and part.startswith("0") for part in prerelease.split(".")
    ):
        raise ValueError("numeric SemVer prerelease identifiers cannot contain leading zeros")


def rewrite_manifest(source, revision, version=None):
    validate_revision(revision)
    if version is not None:
        validate_version(version)
    dependency = f'package: "{LOCAL_NAME}"'
    if source.count(LOCAL_DEPENDENCY) != 1 or dependency not in source:
        raise ValueError("fixture manifest has changed its expected local package dependency")
    requirement = f'revision: "{revision}"' if version is None else f'exact: "{version}"'
    remote = f'.package(url: "{REMOTE_URL}", {requirement})'
    return source.replace(LOCAL_DEPENDENCY, remote).replace(dependency, f'package: "{PACKAGE_ID}"')


def extract_fixtures(archive_bytes, destination):
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            parts = path.parts
            valid_fixture = (
                parts == ("Fixtures",) and member.isdir()
            ) or (
                len(parts) >= 2 and parts[0] == "Fixtures" and parts[1] in FIXTURES
            )
            if path.is_absolute() or ".." in parts or not valid_fixture or not (member.isdir() or member.isfile()):
                raise ValueError(f"unexpected fixture archive entry: {member.name!r}")
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)


def validate_lockfile(lockfile, revision, version=None):
    validate_revision(revision)
    if version is not None:
        validate_version(version)
    resolved = json.loads(lockfile.read_text(encoding="utf-8"))
    pins = resolved.get("pins") if isinstance(resolved, dict) else None
    if not isinstance(pins, list):
        raise ValueError(f"{lockfile}: missing Package.resolved pins")
    selected = [pin for pin in pins if isinstance(pin, dict) and pin.get("identity") == PACKAGE_ID]
    if len(selected) != 1:
        raise ValueError(f"{lockfile}: expected one pin with identity {PACKAGE_ID!r}")
    pin = selected[0]
    for key, expected in (("kind", "remoteSourceControl"), ("location", REMOTE_URL)):
        if pin.get(key) != expected:
            raise ValueError(f"{lockfile}: expected pin {key} {expected!r}, got {pin.get(key)!r}")
    state = pin.get("state")
    if not isinstance(state, dict):
        raise ValueError(f"{lockfile}: expected a pin state")
    if state.get("revision") != revision:
        raise ValueError(f"{lockfile}: expected revision {revision}, got {state.get('revision')!r}")
    if version is not None and state.get("version") != version:
        raise ValueError(f"{lockfile}: expected exact version {version}, got {state.get('version')!r}")
    return {
        "identity": PACKAGE_ID,
        "location": REMOTE_URL,
        "revision": revision,
        "version": state.get("version"),
    }


def tool_output(command, *, cwd=None, env=None, timeout=60):
    return subprocess.check_output(
        [str(part) for part in command], cwd=cwd, env=env, text=True, timeout=timeout,
    ).strip()


def swift_toolchain():
    environment = os.environ.copy()
    if sys.platform == "darwin":
        swift = Path(tool_output(["xcrun", "--find", "swift"]))
        swiftc = Path(tool_output(["xcrun", "--find", "swiftc"]))
        sdk = Path(tool_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"]))
        if not sdk.is_dir():
            raise RuntimeError("xcrun must select an installed macOS SDK")
        environment["SDKROOT"] = str(sdk)
    else:
        swift = Path(shutil.which("swift") or "")
        swiftc = Path(shutil.which("swiftc") or "")
    if any(not path.is_absolute() or not os.access(path, os.X_OK) for path in (swift, swiftc)):
        raise RuntimeError("Swift and swiftc must resolve to executable files")
    if swift.parent.resolve() != swiftc.parent.resolve():
        raise RuntimeError("Swift and swiftc resolve to different toolchains")
    environment["SWIFT_EXEC"] = str(swiftc)
    # These overrides apply only to subprocesses. Do not edit user mirrors or Git config.
    for key in ("BLUEPRINT_EXPECT_FAILURE", "BLUEPRINT_XCTEST_EXPECT_FAILURE",
                "BLUEPRINT_CLOSED_OWNER_BRIDGE",
                "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_DIR", "GIT_WORK_TREE",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(key, None)
    environment.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_TERMINAL_PROMPT="0",
    )
    return swift, environment


def run_fixture(swift, environment, scratch, name, revision, version):
    fixture = scratch / "Fixtures" / name
    manifest = fixture / "Package.swift"
    manifest.write_text(rewrite_manifest(manifest.read_text(encoding="utf-8"), revision, version), encoding="utf-8")
    lock = fixture / "Package.resolved"
    lock.unlink(missing_ok=True)
    if (fixture / ".swiftpm" / "configuration" / "mirrors.json").exists():
        raise ValueError(f"{fixture}: the archived fixture must not use a workspace dependency mirror")
    swiftpm = scratch / "swiftpm"
    command, pass_pattern = FIXTURES[name]
    action, *parameters = command
    log = scratch / f"{name}.log"
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(
            [str(swift), action, "--package-path", str(fixture),
             "--cache-path", str(swiftpm / "cache"), "--config-path", str(swiftpm / "configuration"),
             "--security-path", str(swiftpm / "security"), *parameters],
            cwd=fixture, env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=600, check=False,
        )
    output = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode != 0 or not re.search(pass_pattern, output):
        print(output[-6000:], file=sys.stderr)
        raise RuntimeError(f"{name} did not run successfully; see {log}")
    pin = validate_lockfile(lock, revision, version)
    print(f"PASS {name}: resolved {PACKAGE_ID} at {revision}", flush=True)
    return {"fixture": name, "pin": pin, "log": log.name, "lockfile": str(lock.relative_to(scratch))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision", help="local Git commit or ref to export and verify on GitHub")
    parser.add_argument("--version", metavar="X.Y.Z", help="resolve this exact SemVer and check its commit")
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1],
                        help="local Git checkout supplying the committed fixtures")
    args = parser.parse_args(argv)
    try:
        if args.version is not None:
            validate_version(args.version)
        repository = args.repository.resolve(strict=True)
        revision = tool_output(["git", "rev-parse", "--verify", "--end-of-options", f"{args.revision}^{{commit}}"],
                               cwd=repository)
        validate_revision(revision)
        archive = subprocess.check_output(
            ["git", "archive", "--format=tar", revision, *(f"Fixtures/{name}" for name in FIXTURES)],
            cwd=repository, timeout=60,
        )
        parent = repository / ".build" / "remote-install"
        parent.mkdir(parents=True, exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix=f"{revision[:8]}-", dir=parent))
        print(f"Remote install evidence: {scratch}", flush=True)
        extract_fixtures(archive, scratch)
        swift, environment = swift_toolchain()
        results = [run_fixture(swift, environment, scratch, name, revision, args.version) for name in FIXTURES]
        report = {
            "revision": revision,
            "requirement": {"revision": revision} if args.version is None else {"exact": args.version},
            "repository": REMOTE_URL,
            "swift": subprocess.check_output(
                [str(swift), "--version"], env=environment, text=True,
                stderr=subprocess.STDOUT, timeout=60,
            ).strip(),
            "swiftPath": str(swift),
            "swiftCompilerPath": environment["SWIFT_EXEC"],
            "sdkPath": environment.get("SDKROOT") if sys.platform == "darwin" else None,
            "host": sys.platform,
            "architecture": platform.machine(),
            "results": results,
        }
        (scratch / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("PASS public SwiftPM install through all three consumers", flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Remote install verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
