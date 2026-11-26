#!/usr/bin/env python3
"""Qualify bundled-Xcode configured generation and a SwiftPM consumer offline."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

from verify_inspection import OUTPUT_NAMES
from verify_offline_runtime import (
    FORBIDDEN_LIBRARIES, NETWORK_BLOCK, NETWORK_PROFILE, checked, offline_git_environment, probe_network,
    validate_deployment, validate_mirror_revision,
)
from verify_remote_install import PACKAGE_ID, REMOTE_URL, swift_toolchain
from verify_tooling_install import (
    dependency_nodes, file_origin_matches, git_text, package_command, resolve_lane, stage_fixture, validate_pin,
)


LANE = "offline-configured-generation"
PARSER_LIBRARIES = {"libSwiftParser.dylib", "libSwiftSyntax.dylib"}
INPUT_SET = "91"
SHARD_MARKER = rb"(BlueprintMockingShard_[0-9a-f]+)"
DYLD_IMAGE = re.compile(
    rb"(?m)^dyld\[[0-9]+\]: <[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}> (/[^\r\n]+)$"
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_parser_trace(output, expected):
    if expected.keys() != PARSER_LIBRARIES:
        raise ValueError("The verifier must identify both Xcode host parser libraries")
    observed = {name: [] for name in expected}
    for entry in DYLD_IMAGE.findall(output):
        path = Path(os.fsdecode(entry))
        if path.name in observed:
            observed[path.name].append(path.resolve())
    for name, path in expected.items():
        if observed[name] != [path.resolve()]:
            raise ValueError(f"The generator did not load exactly one approved Xcode {name}: {observed[name]}")


def validate_generated_outputs(normal, offline, *, input_set=INPUT_SET):
    if normal.keys() != set(OUTPUT_NAMES) or not all(normal.values()) or normal != offline:
        raise ValueError("Expected byte-identical configured shard and index from normal and offline generation")
    shard, index = (normal[name] for name in OUTPUT_NAMES)
    markers = re.findall(rb"(?m)^enum " + SHARD_MARKER + rb" \{\}$", shard)
    aliases = re.findall(rb"(?m)^enum BlueprintMockingGeneratedIndex \{ typealias Shard = " + SHARD_MARKER + rb" \}$",
                         index)
    expected_inputs = [f"// SwiftPM input set: {input_set}".encode("ascii")]
    if (len(markers) != 1 or aliases != markers
            or re.findall(rb"(?m)^// SwiftPM input set:[^\n]*$", index) != expected_inputs):
        raise ValueError("The configured index must reference the emitted shard and exact input set")


def read_generated(output):
    files = list(output.iterdir())
    if any(not path.is_file() or path.is_symlink() for path in files):
        raise ValueError("Only regular files belong in the configured generated output")
    return {path.name: path.read_bytes() for path in files}


def verify(repository, revision, mirror, tool, evidence):
    if sys.platform != "darwin":
        raise ValueError("This lane needs the prepared Xcode parser and macOS network sandbox")
    validate_mirror_revision(mirror, revision, offline_git_environment(os.environ))
    swift, environment = swift_toolchain()
    environment = {key: value for key, value in offline_git_environment(environment).items()
                   if not key.startswith("DYLD_")}
    compiler = Path(environment["SWIFT_EXEC"])
    bundled = compiler.parent.parent / "lib/swift/host"
    dylibs = {name: (bundled / name).resolve(strict=True) for name in sorted(PARSER_LIBRARIES)}
    inputs = {str(path): sha256(path) for path in [tool, *dylibs.values()]}
    network = probe_network(environment)
    artifacts = {}

    def run(step, command):
        log = evidence / f"{LANE}-{step}.log"
        output = checked(command, environment, log)
        artifacts[log.name] = sha256(log)
        return output, log

    with tempfile.TemporaryDirectory(prefix="Offline Configured Generation ", dir=evidence) as temporary:
        root = Path(temporary)
        fixture = root / "Consumer"
        state = root / "SwiftPM State"
        runtime_alias = root / f"{PACKAGE_ID}.git"
        runtime_alias.symlink_to(mirror, target_is_directory=True)
        stage_fixture(repository, revision, "OfflineGenerationConsumer", fixture, environment, REMOTE_URL)
        staged_inputs = {str(path.relative_to(fixture)): sha256(path)
                         for path in sorted(fixture.rglob("*")) if path.is_file()}
        output = fixture / "Sources/OfflineProbe/Generated"
        request = [
            "--config", str(fixture / "blueprint-mocking.json"), "--output", str(output),
            "--input-set-id", INPUT_SET, "--source", "OfflineDomain",
            str(fixture / "Sources/OfflineDomain/Lookup.swift"),
        ]
        traced_tool = ["/usr/bin/env", "DYLD_PRINT_LIBRARIES=1", str(tool)]
        host_commands, _ = run("host-deployment", ["/usr/bin/otool", "-l", str(tool)])
        validate_deployment(host_commands, "15.0")

        outputs = {}
        for mode, prefix in (("normal", []), ("offline", NETWORK_BLOCK)):
            if output.exists():
                raise ValueError(f"{mode} generation did not start with an absent output directory")
            _, trace = run(f"{mode}-generation", prefix + traced_tool + ["generate", *request])
            validate_parser_trace(trace.read_bytes(), dylibs)
            outputs[mode] = read_generated(output)
            if mode == "normal":
                output.rename(root / "Normal Output")
        normal, offline = outputs["normal"], outputs["offline"]
        validate_generated_outputs(normal, offline)
        for mode, files in outputs.items():
            for name, content in files.items():
                copy = evidence / f"{LANE}-{mode}-{name}"
                copy.write_bytes(content)
                artifacts[copy.name] = sha256(copy)

        verified, _ = run("offline-verify-generated", NETWORK_BLOCK + [str(tool), "verify-generated", *request])
        if verified != b"Blueprint Mocking: verified 2 generated file(s)\n":
            raise ValueError("The generator must verify both configured outputs under network denial")

        resolver = NETWORK_BLOCK + package_command(swift, fixture, state) + ["--disable-sandbox"]
        graph, pins, resolved_hashes = resolve_lane(
            resolver, fixture, evidence, LANE, environment, mirror=(REMOTE_URL, str(runtime_alias)),
        )
        node = dependency_nodes(graph, {PACKAGE_ID})[PACKAGE_ID]
        dependency_nodes(node, set())
        if set(pins) != {PACKAGE_ID} or not file_origin_matches(node["url"], runtime_alias):
            raise ValueError("The generated consumer resolved a dependency outside the prepared mirror")
        validate_pin(pins[PACKAGE_ID], revision, runtime_alias, original_url=REMOTE_URL)
        lock = (fixture / "Package.resolved").read_bytes()
        checkout = Path(node["path"]).resolve(strict=True)
        artifacts.update(resolved_hashes)
        builder = NETWORK_BLOCK + package_command(swift, fixture, state, action="build") + [
            "--disable-sandbox", "--build-system", "native", "--force-resolved-versions",
            "--disable-index-store", "--jobs", "4", "--product", "OfflineProbe",
        ]
        run("consumer-build", builder)
        bin_output, _ = run("consumer-bin-path", builder + ["--show-bin-path"])
        executable = (Path(os.fsdecode(bin_output.strip())) / "OfflineProbe").resolve(strict=True)
        if (not executable.is_relative_to(state) or not checkout.is_relative_to(state / "build/checkouts")
                or git_text(checkout, ["rev-parse", "HEAD"], environment) != revision
                or (fixture / "Package.resolved").read_bytes() != lock):
            raise ValueError("The built consumer must retain the isolated runtime pin and executable")
        result, _ = run("consumer-run", NETWORK_BLOCK + [str(executable)])
        if result != b"PASS: DX020 configured generated consumer\n":
            raise ValueError("The independent consumer did not execute the generated protocol workflow")
        consumer_commands, _ = run("consumer-deployment", ["/usr/bin/otool", "-l", str(executable)])
        validate_deployment(consumer_commands, "13.0")
        linkage, _ = run("consumer-linkage", ["/usr/bin/otool", "-L", str(executable)])
        if any(name in linkage.lower() for name in FORBIDDEN_LIBRARIES):
            raise ValueError("Unexpected generator or test-runner linkage in the generated consumer")
        if (read_generated(output) != offline
                or {name: sha256(fixture / name) for name in staged_inputs} != staged_inputs
                or any(sha256(Path(path)) != digest for path, digest in inputs.items())):
            raise ValueError("A verification input or generated output changed during the lane")

        report = {
            "sourceRevision": revision,
            "parser": "Xcode toolchain host SwiftParser and SwiftSyntax dynamic libraries",
            "swiftCompiler": str(compiler),
            "compilerVersion": subprocess.check_output([str(compiler), "--version"], env=environment, text=True).strip(),
            "sdk": environment["SDKROOT"],
            "host": platform.platform(),
            "hostBuild": subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip(),
            "generatorDeploymentTarget": "macOS 15.0",
            "consumerDeploymentTarget": "macOS 13.0",
            "consumerSHA256": sha256(executable),
            "networkPolicy": NETWORK_PROFILE,
            "networkProbe": network,
            "inputSetID": INPUT_SET,
            "stagedInputSHA256": staged_inputs,
            "generatorAndParserSHA256": inputs,
            "artifacts": artifacts,
        }
    path = evidence / f"{LANE}-report.json"
    path.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: bundled Xcode parser generated identical shard and index bytes with networking denied")
    print("PASS: independent configured SwiftPM consumer built and ran with networking denied")
    print(f"EVIDENCE: {path.name} SHA-256 {sha256(path)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision")
    parser.add_argument("--runtime-mirror", type=Path, required=True)
    parser.add_argument("--tool", type=Path, required=True, help="Canonical generator built by scripts/generate.sh")
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        evidence = args.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / f"{LANE}-report.json").unlink(missing_ok=True)
        verify(args.repository.resolve(strict=True), args.revision, args.runtime_mirror.resolve(strict=True),
               args.tool.resolve(strict=True), evidence)
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Offline configured-generation verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
