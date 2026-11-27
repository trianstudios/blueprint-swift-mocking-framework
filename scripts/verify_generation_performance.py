#!/usr/bin/env python3
"""Measure report-only D4.3 configured generation with a prepared macOS generator."""

import argparse
from decimal import Decimal
from functools import partial
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import stat
import statistics
import subprocess
import sys
import tempfile
import time

from check_release import read_json
from verify_inspection import MODULE, OUTPUT_NAMES, arguments, sha256, snapshot
from verify_offline_runtime import NETWORK_BLOCK, offline_git_environment
from verify_parser_parity import PARSER_LIBRARIES, compiler_receipt_context, verify_receipt
from verify_runtime_performance import clean_revision, command, digest
from verify_remote_install import swift_toolchain

DECLARATIONS = 1_000
COLD_METHODS = 10
PROTOCOLS_PER_FILE = 100
WARM_TARGET_NS = 250_000_000
COLD_TARGET_NS = 5_000_000_000
COLD_TARGET_BYTES = 512 * 1024 * 1024
REPORT = "generation-performance.json"
TIMING_PREFIX = b"DX032_GENERATION_TIME_V1 "
TIMING_NONCE = "BLUEPRINT_GENERATION_TIMING_NONCE"
TIMING_FLAG = "BLUEPRINT_MEASURE_GENERATION"
TIME_HEADER = re.compile(rb"\s*([0-9]+(?:\.[0-9]+)?) real\s+([0-9]+(?:\.[0-9]+)?) user\s+([0-9]+(?:\.[0-9]+)?) sys\s*")
TIME_COUNT = re.compile(rb"\s*([0-9]+)\s+([a-z][a-z0-9 ()/_-]+)\s*")
MOCK = re.compile(rb"(?m)^public final class (ScaleProtocol[0-9]{4})Mock:")
WITNESS = re.compile(rb"(?m)^    public func scaleMethod([0-9]{2})\(")


def parse_darwin_time(stderr):
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    if not lines or not (elapsed := TIME_HEADER.fullmatch(lines[0])):
        raise ValueError("Missing macOS elapsed/user/sys meter header or unexpected generator diagnostic")
    counts = {}
    for line in lines[1:]:
        meter = TIME_COUNT.fullmatch(line)
        if meter is None or meter[2] in counts:
            raise ValueError("Unexpected generator diagnostic or duplicate macOS meter field")
        counts[meter[2]] = int(meter[1])
    resident = counts.get(b"maximum resident set size", 0)
    if resident <= 0:
        raise ValueError("Missing positive maximum resident set size")
    wall, user, system = (int(Decimal(value.decode("ascii")) * 1_000_000_000) for value in elapsed.groups())
    return {"meterWallNanos": wall, "userCPUNanos": user, "systemCPUNanos": system, "peakResidentBytes": resident}


def make_corpus(root, count, methods):
    if not 1 <= count <= DECLARATIONS or not 1 <= methods <= COLD_METHODS:
        raise ValueError("Generation fixture dimensions exceed the declared bounds")
    root.mkdir()
    protocols = [f"ScaleProtocol{index:04d}" for index in range(count)]
    requirements = "".join(
        f"    func scaleMethod{index:02d}(_ value: Int) -> Int\n" for index in range(methods)
    )
    paths = []
    for first in range(0, count, PROTOCOLS_PER_FILE):
        path = root / f"Source{first // PROTOCOLS_PER_FILE:02d}.swift"
        path.write_text("".join(f"public protocol {name}: Sendable {{\n{requirements}}}\n\n"
                                for name in protocols[first:first + PROTOCOLS_PER_FILE]), encoding="utf-8")
        paths.append(path)
    config = root / "blueprint-mocking.json"
    config.write_text(json.dumps({"schemaVersion": 1, "selections": [
        {"module": MODULE, "type": name, "kind": "protocol"} for name in protocols
    ]}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return config, paths, {
        "sourceProtocolDeclarations": count, "selectedRequirements": count * methods,
        "requirementsPerProtocol": methods, "sourceFiles": len(paths),
        "overloadGroups": 0, "signature": "nonisolated synchronous Int -> Int",
        "authoredFiles": {path.name: {"bytes": path.stat().st_size, "sha256": digest(path)} for path in [config, *paths]},
    }


def output_state(directory, count, methods):
    state = snapshot(directory)
    if state.keys() != {".", *OUTPUT_NAMES}:
        raise ValueError("Expected exactly the configured shard and index")
    for name in OUTPUT_NAMES:
        mode, _, size, _, _ = state[name]
        if not stat.S_ISREG(mode) or size <= 0:
            raise ValueError(f"Expected a nonempty regular output: {name}")
    shard = (directory / OUTPUT_NAMES[0]).read_bytes()
    matches = list(MOCK.finditer(shard))
    expected_protocols = {f"ScaleProtocol{index:04d}".encode("ascii") for index in range(count)}
    if len(matches) != count or {match[1] for match in matches} != expected_protocols:
        raise ValueError("Generated mock names or count differ from the configured corpus")
    expected_witnesses = [f"{index:02d}".encode("ascii") for index in range(methods)]
    ends = [*(match.start() for match in matches[1:]), len(shard)]
    for match, end in zip(matches, ends, strict=True):
        if sorted(WITNESS.findall(shard, match.end(), end)) != expected_witnesses:
            raise ValueError(f"Incorrect generated witness count or selectors for {match[1].decode('ascii')}")
    return state


def require_unchanged(directory, previous):
    if snapshot(directory) != previous:
        raise ValueError(f"Expected no-op generation to preserve output bytes, identities and mtimes: {directory.name}")



def parse_component_timing(stderr, nonce, spawned, exited):
    lines = stderr.splitlines(keepends=True)
    marks = [line for line in lines if line.startswith(TIMING_PREFIX)]
    if len(marks) != 1 or lines[0] != marks[0]:
        raise ValueError("Expected exactly one configured generation timing record before the process meter")
    fields = marks[0][len(TIMING_PREFIX):].strip().split()
    if len(fields) != 4 or fields[0] != nonce.encode("ascii"):
        raise ValueError("Configured generation timing nonce does not match this process")
    if any(re.fullmatch(rb"[0-9]{1,20}", value) is None for value in fields[1:]):
        raise ValueError("Configured generation timing requires integer nanoseconds")
    entry, begin, end = map(int, fields[1:])
    if not spawned <= entry <= begin < end <= exited:
        raise ValueError("Configured generation timing is outside its monotonic clock window")
    return b"".join(lines[1:]), {
        "launchToSwiftEntryNanos": entry - spawned,
        "argumentDispatchNanos": begin - entry,
        "configuredGenerationNanos": end - begin,
        "afterSwiftEntryNanos": end - entry,
        "completionToExitNanos": exited - end,
    }


def component_build_profile(directory, receipt_digest, revision, environment):
    profile_path = directory / "build-provenance.json"
    profile = read_json(profile_path.read_bytes(), "configured generation timing build provenance")
    names = {
        "sourceArchiveSHA256": "source.tar",
        "buildCommandSHA256": "build.command",
        "buildMeterSHA256": "build.meter-stderr",
        "linkageSHA256": "bundled-linkage.log",
    }
    if profile["bundledReceiptSHA256"] != receipt_digest or any(
            digest(directory / name) != profile[key] for key, name in names.items()):
        raise ValueError("Configured generation timing build provenance differs from its artifacts")
    arguments_record = shlex.split((directory / "build.command").read_text(encoding="utf-8"))
    definitions = [next_argument if argument == "-D" else argument[2:]
                   for argument, next_argument in zip(arguments_record, [*arguments_record[1:], ""])
                   if argument.startswith("-D")]
    optimizations = [argument for argument in arguments_record
                     if argument in {"-Onone", "-O", "-Osize", "-Ounchecked"}]
    if (not arguments_record or arguments_record[0] != environment["SWIFT_EXEC"]
            or profile["buildOptimization"] != "-Onone" or optimizations != ["-Onone"]
            or definitions != [TIMING_FLAG]):
        raise ValueError("Expected the bundled generator build with only its generation timing flag")
    with (directory / "source.tar").open("rb") as archive:
        archived = subprocess.check_output(["git", "get-tar-commit-id"], stdin=archive, env=environment,
                                           text=True, timeout=15).strip()
    if archived != revision:
        raise ValueError("Configured generation timing build archive revision does not match the receipt")
    return profile | {
        "provenanceSHA256": digest(profile_path),
        "meter": parse_darwin_time((directory / "build.meter-stderr").read_bytes()),
    }

def run_timed(tool, root, configuration, output, sources, evidence, label, environment, count, *, component_timing=False):
    request = arguments(configuration, output, sources)
    argv = ["/usr/bin/time", "-l", *NETWORK_BLOCK, str(tool), "generate", *request]
    clock = time.perf_counter_ns
    if component_timing:
        clock = partial(time.clock_gettime_ns, time.CLOCK_MONOTONIC)
        nonce = secrets.token_hex(16)
        environment = environment | {TIMING_NONCE: nonce}
    start = clock()
    child = subprocess.run(argv, cwd=root, env=environment, capture_output=True, timeout=90, check=False)
    end = clock()
    (evidence / f"{label}.stdout").write_bytes(child.stdout)
    (evidence / f"{label}.meter-stderr").write_bytes(child.stderr)
    stamp = f"Blueprint Mocking: generated {count} protocol mock(s)\n".encode("ascii")
    if child.returncode or child.stdout != stamp:
        raise ValueError(f"{label}: generation did not produce the exact expected stamp (exit {child.returncode})")
    stderr = child.stderr
    timing = {}
    if component_timing:
        stderr, component = parse_component_timing(stderr, nonce, start, end)
        timing["componentTiming"] = component
    return parse_darwin_time(stderr) | {"processWallNanos": end - start} | timing


def benchmark(tool, evidence, environment, count, cold_methods, warm_repeats, *, invoke=run_timed):
    if not 1 <= warm_repeats <= 15:
        raise ValueError("Choose between 1 and 15 warm repetitions")
    with tempfile.TemporaryDirectory(prefix="generation-scale-", dir=evidence) as directory:
        temporary = Path(directory)
        modes = {}
        for label, methods in (("cold", cold_methods), ("warm", 1)):
            root = temporary / label
            config, sources, corpus = make_corpus(root, count, methods)
            input_state = snapshot(root)
            output = root / "Generated"
            if label == "warm":
                output.mkdir()
            initial = "existing empty output directory" if label == "warm" else "output directory absent"
            seed_label = "warm-seed" if label == "warm" else label
            seed = invoke(tool, root, config, output, sources, evidence, seed_label, environment, count)
            published = output_state(output, count, methods)
            modes[label] = {
                "fixture": corpus, "initialOutputState": initial, "initialProcess": seed,
                "generatedFiles": {name: {"bytes": published[name][2], "mtimeNanos": published[name][3],
                                         "sha256": published[name][4]} for name in OUTPUT_NAMES},
            }
            if label == "warm":
                samples = []
                for repetition in range(1, warm_repeats + 1):
                    samples.append(invoke(tool, root, config, output, sources, evidence,
                                          f"warm-{repetition}", environment, count))
                    require_unchanged(output, published)
                modes[label].update(
                    samples=samples, noOpFilesPreserved=True, steadyOutputState="two unchanged generated files",
                    medianProcessWallNanos=statistics.median(row["processWallNanos"] for row in samples),
                    launchExcludedMedianNanos=None,
                )
            after = snapshot(root)
            # First publication changes the root mtime and creates only the configured output directory.
            authored = {name: value for name, value in after.items()
                        if name != "." and name != "Generated" and not name.startswith("Generated/")}
            if authored != {name: value for name, value in input_state.items() if name != "."}:
                raise ValueError(f"{label}: generation changed authored inputs")
    launch = None
    steady = [row.get("componentTiming") for row in modes["warm"]["samples"]]
    if any(sample is not None for sample in steady):
        if any(sample is None for sample in steady):
            raise ValueError("Configured generation timing is incomplete across warm samples")
        modes["warm"]["launchExcludedMedianNanos"] = statistics.median(
            sample["afterSwiftEntryNanos"] for sample in steady
        )
        modes["warm"]["configuredGenerationMedianNanos"] = statistics.median(
            sample["configuredGenerationNanos"] for sample in steady
        )
        launch = statistics.median(sample["launchToSwiftEntryNanos"] for sample in steady)
    return modes | {
        "status": "report-only",
        "certificationVerdict": None, "regressionVerdict": None, "clientCompileImpact": None,
        "toolLaunchNanos": launch, "toolBuildNanos": None, "buildOptimizationFromReceipt": None,
        "publishedD43Targets": {
            "warm": {"sourceProtocolDeclarations": DECLARATIONS, "medianExcludingLaunchAndBuildNanos": WARM_TARGET_NS},
            "cold": {"sourceProtocolDeclarations": DECLARATIONS, "selectedRequirements": DECLARATIONS * COLD_METHODS,
                     "elapsedNanos": COLD_TARGET_NS, "peakResidentBytes": COLD_TARGET_BYTES},
        },
        "measurementScope": "fresh child per sample; OS file caches untouched; tool already built; wall includes tool launch",
    }


def verify(repository, tool, receipt_path, evidence, warm_repeats, smoke, component_build=None):
    if sys.platform != "darwin":
        raise ValueError("This driver uses the native macOS process meter and bundled generator")
    _, selected = swift_toolchain()
    environment = offline_git_environment(selected) | {"GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "LANG": "C"}
    environment = {key: value for key, value in environment.items()
                   if not key.startswith("DYLD_") and key != TIMING_NONCE}
    revision = clean_revision(repository, environment)
    common = compiler_receipt_context(revision, environment)
    compiler = Path(common["swiftCompiler"])
    host_libraries = compiler.parent.parent / "lib/swift/host"
    parsers = {name: digest(host_libraries / name) for name in sorted(PARSER_LIBRARIES)}
    if not tool.is_file() or not os.access(tool, os.X_OK):
        raise ValueError("Provide the prepared executable bundled generator")
    receipt_digest = digest(receipt_path)
    receipt = verify_receipt(receipt_path, common, "bundled", tool, {"parserSHA256": parsers})
    build = None
    if component_build is not None:
        build = component_build_profile(component_build, receipt_digest, revision, environment)
    if evidence.is_relative_to(repository):
        relative = evidence.relative_to(repository)
        result = subprocess.run(["git", "-C", repository, "check-ignore", "--quiet", "--", relative],
                                env=environment, timeout=10)
        if result.returncode:
            raise ValueError("Use an ignored or external evidence directory")
    evidence.mkdir(parents=True, exist_ok=True)
    if any(evidence.iterdir()):
        raise ValueError("Use an empty evidence directory")
    result = benchmark(tool, evidence, environment, 3 if smoke else DECLARATIONS,
                       2 if smoke else COLD_METHODS, warm_repeats,
                       invoke=partial(run_timed, component_timing=build is not None))
    if build is not None:
        if component_build_profile(component_build, receipt_digest, revision, environment) != build:
            raise ValueError("Configured generation timing build artifacts changed during measurement")
        result.update(
            componentBuildEvidence=build, toolBuildNanos=build["meter"]["meterWallNanos"],
            componentTimingScope="Darwin CLOCK_MONOTONIC; spawn to Swift entry includes meter, sandbox and loader; "
                                 "entry to configured completion includes argument dispatch; compiler-only meter is separate",
        )
    if (clean_revision(repository, environment) != revision or digest(tool) != receipt["executableSHA256"]
            or digest(receipt_path) != receipt_digest
            or any(digest(host_libraries / name) != digest_value for name, digest_value in parsers.items())
            or verify_receipt(receipt_path, common, "bundled", tool, {"parserSHA256": parsers}) != receipt):
        raise ValueError("Source, executable, parser libraries or build receipt changed during measurement")
    result.update(
        schemaVersion=1, scaleMode="smoke" if smoke else "declared-scale",
        generatorBuildReceipt=receipt, generatorBuildReceiptSHA256=receipt_digest,
        driverSHA256=digest(Path(__file__)),
        host=command(["/usr/bin/sw_vers"], environment),
        machine=platform.machine(), hardwareModel=command(["/usr/sbin/sysctl", "-n", "hw.model"], environment),
        artifacts={path.name: digest(path) for path in sorted(evidence.iterdir())},
    )
    path = evidence / REPORT
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"EVIDENCE: {path.name} SHA-256 {digest(path)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--bundled-receipt", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--warm-repeats", type=int, default=5)
    parser.add_argument("--component-build-evidence", type=Path,
                        help="Measure the receipted benchmark-only binary with its exact bundled build artifacts")
    parser.add_argument("--smoke", action="store_true", help="Use a scaled-down structural check without budget claims")
    args = parser.parse_args()
    try:
        verify(args.repository.resolve(), args.tool.resolve(), args.bundled_receipt.resolve(),
               args.evidence_dir.resolve(), args.warm_repeats, args.smoke,
               args.component_build_evidence.resolve() if args.component_build_evidence else None)
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Generation performance measurement failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
