#!/usr/bin/env python3
"""Build and run the exact runtime-only SwiftPM consumer with macOS networking denied."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import socket
import subprocess
import sys
import tempfile

from verify_remote_install import PACKAGE_ID, REMOTE_URL, swift_toolchain, validate_revision
from verify_tooling_install import (
    dependency_nodes, file_origin_matches, git_text, package_command, resolve_lane, stage_fixture, validate_pin,
)


NETWORK_PROFILE = "(version 1)(allow default)(deny network*)"
NETWORK_BLOCK = ["/usr/bin/sandbox-exec", "-p", NETWORK_PROFILE]
OBJECT_TARGETS = {"BlueprintMocking.build", "RuntimeOnly.build"}
FORBIDDEN_LIBRARIES = (
    b"swiftsyntax", b"swiftparser", b"sourcekit", b"testing", b"xctest", b"blueprintmockingcli", b"blueprint-mocking",
)


def offline_git_environment(environment):
    return {key: value for key, value in environment.items() if not key.startswith("GIT_")} | {
        "GIT_ALLOW_PROTOCOL": "file",
        "GIT_PROTOCOL_FROM_USER": "0",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }


def validate_mirror_revision(mirror, revision, environment):
    validate_revision(revision)
    try:
        bare = git_text(mirror, ["rev-parse", "--is-bare-repository"], environment)
        kind = git_text(mirror, ["cat-file", "-t", revision], environment)
    except subprocess.CalledProcessError as error:
        raise ValueError("The prepared runtime mirror must contain the exact commit") from error
    if bare != "true" or kind != "commit":
        raise ValueError("The prepared runtime mirror must be bare and contain the exact commit")
    integrity = subprocess.run(
        ["git", "-C", str(mirror), "fsck", "--full", "--strict", "--no-reflogs", "--no-dangling",
         "--no-progress", revision],
        env=environment | {"LC_ALL": "C"}, capture_output=True, timeout=60,
    )
    if integrity.returncode:
        detail = (integrity.stderr or integrity.stdout).decode(errors="replace").strip()[:4000]
        raise ValueError(f"Runtime mirror failed Git object integrity check for {revision}: {detail}")


def validate_network_probe(allowed, blocked):
    if (allowed.returncode != 0 or allowed.stdout != b"BLUEPRINT_LOOPBACK_CONNECTED\n" or allowed.stderr
            or blocked.returncode not in (errno.EPERM, errno.EACCES)
            or blocked.stdout != f"BLUEPRINT_LOOPBACK_ERRNO={blocked.returncode}\n".encode() or blocked.stderr):
        raise ValueError(f"The network probe needs a successful control and child-reported permission denial "
                         f"(exits {allowed.returncode}, {blocked.returncode})")


def probe_network(environment):
    connect = """import socket, sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3).close()
except OSError as error:
    print(f"BLUEPRINT_LOOPBACK_ERRNO={error.errno}")
    sys.exit(error.errno or 125)
print("BLUEPRINT_LOOPBACK_CONNECTED")
"""
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        command = [sys.executable, "-c", connect, str(listener.getsockname()[1])]
        allowed = subprocess.run(command, env=environment, capture_output=True, timeout=10)
        blocked = subprocess.run(NETWORK_BLOCK + command, env=environment, capture_output=True, timeout=10)
    validate_network_probe(allowed, blocked)
    return {
        "control": {"exit": allowed.returncode, "stdout": allowed.stdout.decode("ascii").strip()},
        "blocked": {"exit": blocked.returncode, "stdout": blocked.stdout.decode("ascii").strip()},
    }


def validate_linkage(dynamic, linked_objects):
    header, *libraries = dynamic.splitlines()
    if (not header.endswith(b":") or not libraries
            or any(line == line.lstrip() or b" (compatibility version " not in line for line in libraries)):
        raise ValueError("Missing Mach-O dynamic library inspection")
    if any(name in line.lower() for line in libraries for name in FORBIDDEN_LIBRARIES):
        raise ValueError("Runtime-only executable links a parser, generator or reporter library")
    targets = set()
    for entry in linked_objects.decode("utf-8").splitlines():
        entry = entry.strip()
        paths = shlex.split(entry) if entry.startswith(("'", '"')) else [entry]
        if len(paths) != 1:
            raise ValueError(f"Expected one path for runtime-only link object {entry!r}")
        path = Path(paths[0])
        if not path.is_absolute() or path.suffix != ".o" or path.parent.name not in OBJECT_TARGETS:
            raise ValueError(f"Unexpected runtime-only link object {entry!r}")
        targets.add(path.parent.name)
    if targets != OBJECT_TARGETS:
        raise ValueError("The executable must include both the runtime and the consumer objects")


def checked(command, environment, log):
    result = subprocess.run(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=240)
    log.write_bytes(result.stdout + result.stderr)
    if result.returncode != 0:
        detail = log.read_text(encoding="utf-8", errors="replace")[-4000:]
        raise RuntimeError(f"Command exited {result.returncode}. See {log}\n{detail}")
    return result.stdout


def verify(repository, revision, mirror, evidence):
    if sys.platform != "darwin":
        raise ValueError("This runtime qualification requires the macOS network sandbox and Mach-O tools")
    validate_mirror_revision(mirror, revision, offline_git_environment(os.environ))
    swift, environment = swift_toolchain()
    environment = offline_git_environment(environment)
    network = probe_network(environment)

    lane = "runtime-only-offline"
    evidence.mkdir(parents=True, exist_ok=True)
    report_path = evidence / f"{lane}-report.json"
    report_path.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="Offline Runtime ", dir=evidence) as temporary:
        root = Path(temporary)
        alias = root / f"{PACKAGE_ID}.git"
        alias.symlink_to(mirror, target_is_directory=True)
        fixture = root / "Consumer"
        state = root / "SwiftPM State"
        stage_fixture(repository, revision, "RuntimeOnly", fixture, environment, REMOTE_URL)
        resolver = NETWORK_BLOCK + package_command(swift, fixture, state) + ["--disable-sandbox"]
        graph, pins, hashes = resolve_lane(resolver, fixture, evidence, lane, environment,
                                            mirror=(REMOTE_URL, str(alias)))
        dependency, = dependency_nodes(graph, {PACKAGE_ID}).values()
        dependency_nodes(dependency, set())
        if set(pins) != {PACKAGE_ID} or not file_origin_matches(dependency["url"], alias):
            raise ValueError("The runtime was not resolved solely from the prepared mirror")
        validate_pin(pins[PACKAGE_ID], revision, alias, original_url=REMOTE_URL)
        checkout = Path(dependency["path"]).resolve(strict=True)
        if not checkout.is_relative_to(state / "build/checkouts"):
            raise ValueError("Expected a separately installed SwiftPM checkout")
        lockfile = fixture / "Package.resolved"
        lock = lockfile.read_bytes()

        builder = NETWORK_BLOCK + package_command(swift, fixture, state, action="build") + [
            "--disable-sandbox", "--build-system", "native", "--force-resolved-versions",
            "--disable-index-store", "--jobs", "4", "--product", "RuntimeOnly",
        ]
        build_log = evidence / f"{lane}-build.log"
        checked(builder, environment, build_log)
        bin_log = evidence / f"{lane}-bin-path.log"
        bin_path = Path(checked(builder + ["--show-bin-path"], environment, bin_log).decode().strip())
        if not bin_path.resolve(strict=True).is_relative_to(state):
            raise ValueError("SwiftPM returned an executable location outside the isolated build")
        if (git_text(checkout, ["rev-parse", "HEAD"], environment) != revision
                or lockfile.read_bytes() != lock):
            raise ValueError("The build did not retain the resolved runtime revision")

        executable = bin_path / "RuntimeOnly"
        run_log = evidence / f"{lane}-run.log"
        if checked(NETWORK_BLOCK + [str(executable)], environment, run_log) != b"PASS: runtime-only consumer\n":
            raise ValueError("The installed runtime consumer did not pass its typed smoke assertions")
        linkage_log = evidence / f"{lane}-linkage.log"
        dynamic = checked(NETWORK_BLOCK + ["/usr/bin/otool", "-L", str(executable)], environment, linkage_log)
        objects = (bin_path / "RuntimeOnly.product/Objects.LinkFileList").read_bytes()
        validate_linkage(dynamic, objects)
        object_log = evidence / f"{lane}-link-objects.log"
        object_log.write_bytes(objects)
        deployment_log = evidence / f"{lane}-deployment.log"
        load_commands = checked(NETWORK_BLOCK + ["/usr/bin/otool", "-l", str(executable)], environment, deployment_log)
        if not re.search(rb"(?m)^\s+cmd LC_BUILD_VERSION\n\s+cmdsize \d+\n\s+platform 1\n\s+minos 13\.0\n",
                         load_commands):
            raise ValueError("The consumer Mach-O deployment target must be macOS 13.0")
        hashes.update({path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                       for path in (build_log, bin_log, run_log, linkage_log, object_log, deployment_log)})
        report = {
            "sourceRevision": revision,
            "swift": str(swift),
            "compiler": subprocess.check_output([str(swift), "--version"], env=environment, text=True,
                                                stderr=subprocess.STDOUT).strip(),
            "sdk": environment["SDKROOT"],
            "sdkVersion": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                                                  env=environment, text=True).strip(),
            "host": platform.platform(),
            "hostBuild": subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip(),
            "deploymentTarget": "macOS 13.0",
            "buildSystem": "native",
            "languageMode": "6",
            "gitTransport": "file-only",
            "gitObjectIntegrity": "git fsck --full --strict",
            "networkPolicy": NETWORK_PROFILE,
            "networkProbe": network,
            "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "artifacts": hashes,
        }
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: runtime-only consumer resolved, built and ran from its exact mirror with networking denied")
    print("PASS: runtime-only linkage contains only core and consumer objects")
    print(f"EVIDENCE: {report_path.name} SHA-256 {hashlib.sha256(report_path.read_bytes()).hexdigest()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision", help="Exact commit supplying the consumer and present in the prepared mirror")
    parser.add_argument("--runtime-mirror", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        evidence = args.evidence_dir.resolve()
        verify(args.repository.resolve(strict=True), args.revision, args.runtime_mirror.resolve(strict=True), evidence)
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Offline runtime verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
