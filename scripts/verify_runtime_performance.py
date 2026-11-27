#!/usr/bin/env python3
"""Collect report-only DX-032 evidence from an exact optimized macOS SwiftPM consumer."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import shlex
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

from verify_offline_runtime import NETWORK_BLOCK, checked, offline_git_environment, validate_deployment
from verify_remote_install import swift_toolchain, validate_revision
from verify_tooling_install import git_text, package_command

ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = {"latency": (1, 10_000), "admission": (8, 100_000), "retirement": (1, 2_000)}
LATENCY_TARGET_NS = 2_000


def number(value, key, *, positive=False):
    item = value.get(key)
    if type(item) is not int or item < int(positive):
        raise ValueError(f"Missing or invalid {key}")
    return item


def exact(value, key, expected):
    item = value.get(key)
    if type(item) is not type(expected) or item != expected:
        raise ValueError(f"{key} must be {expected!r}")


def object_field(value, key):
    item = value.get(key)
    if not isinstance(item, dict):
        raise ValueError(f"Missing or invalid {key}")
    return item


def validate_sample(mode, row):
    if mode not in WORKLOADS or not isinstance(row, dict):
        raise ValueError("Invalid workload or sample")
    workers, calls = WORKLOADS[mode]
    for key, expected in (("mode", mode), ("workers", workers), ("calls", calls)):
        exact(row, key, expected)
    heaps = ["heapBefore", "heapAfter"]
    if mode == "retirement":
        heaps.append("heapAfterReset")
    for field in heaps:
        heap = object_field(row, field)
        number(heap, "liveBlocks")
        number(heap, "liveBytes")
    number(row, "peakResidentBytes", positive=True)
    if mode == "retirement":
        for key, expected in (
            ("releasedBeforeReset", 0), ("releasedAfterReset", calls),
            ("activeAfterFinish", 0), ("eventsAfterFinish", 0), ("finished", True),
        ):
            exact(row, key, expected)
        number(row, "resetNanos", positive=True)
        number(row, "finishNanos", positive=True)
        return row

    number(row, "durationNanos", positive=True)
    history = object_field(row, "history")
    for key in ("admissions", "returns", "uniqueAdmissions", "uniqueReturns", "typedReturnedMatches"):
        exact(history, key, calls)
    for key in ("identitySetsMatch", "epochMatches", "unpruned"):
        exact(history, key, True)
    exact(history, "active", 0)
    if mode == "latency":
        exact(row, "warmupCalls", 2_000)
        percentiles = object_field(row, "percentilesNanos")
        values = [percentiles.get(key) for key in ("p50", "p95", "p99")]
        if any(type(value) is not int or value <= 0 for value in values) or values != sorted(values):
            raise ValueError("Latency percentile values must be positive and ordered")
    return row


def summarize(samples):
    output = {}
    for mode in WORKLOADS:
        rows = samples.get(mode)
        if not rows:
            raise ValueError(f"No {mode} samples")
        output[mode] = []
        for row in rows:
            validate_sample(mode, row)
            heap = row["heapAfter"]
            before = row["heapBefore"]
            summary = {
                "netLiveBlocks": heap["liveBlocks"] - before["liveBlocks"],
                "netLiveBytes": heap["liveBytes"] - before["liveBytes"],
            }
            if mode == "retirement":
                summary["netLiveBytesAfterReset"] = row["heapAfterReset"]["liveBytes"] - before["liveBytes"]
            if mode == "admission":
                summary["callsPerSecond"] = (row["calls"] * 1_000_000_000) / row["durationNanos"]
            output[mode].append(summary)
    medians = [row["percentilesNanos"]["p50"] for row in samples["latency"]]
    return output | {
        "medianOfSampleMediansNanos": statistics.median(medians),
        "absoluteMedianLatencyTargetNanos": LATENCY_TARGET_NS,
        "samplesAtOrBelowLatencyTarget": sum(value <= LATENCY_TARGET_NS for value in medians),
        "regressionVerdict": None,
        "certificationVerdict": None,
    }


def clean_revision(repository, environment):
    if Path(git_text(repository, ["rev-parse", "--show-toplevel"], environment)) != repository:
        raise ValueError("Run the performance verifier from the exact Git root")
    revision = git_text(repository, ["rev-parse", "--verify", "HEAD^{commit}"], environment)
    validate_revision(revision)
    if git_text(repository, ["status", "--porcelain=v1", "--untracked-files=normal"], environment):
        raise ValueError("Performance evidence requires a clean checkout")
    return revision


def validate_dependencies(graph, staged_source):
    if not isinstance(graph, dict):
        raise ValueError("Expected a SwiftPM dependency graph")
    dependencies = graph.get("dependencies")
    if not isinstance(dependencies, list) or len(dependencies) != 1:
        raise ValueError("Expected exactly one dependency, the archived local runtime")
    runtime = dependencies[0]
    if not isinstance(runtime, dict) or not isinstance(runtime.get("path"), str) or Path(runtime["path"]).resolve() != staged_source.resolve():
        raise ValueError("Expected the exact archived runtime path")
    if runtime.get("dependencies") != []:
        raise ValueError("Expected no transitive dependencies underneath the runtime")


def validate_release_compilation(build_log):
    targets = {"BlueprintMocking", "RuntimePerformanceProbe"}
    optimized = set()
    for line in build_log.splitlines():
        if " -module-name " not in line:
            continue
        fields = shlex.split(line)
        if not fields or Path(fields[0]).name not in {"swiftc", "swift-frontend"}:
            continue
        target = fields[fields.index("-module-name") + 1]
        if target in targets and ("-c" in fields or "-emit-module" in fields):
            if "-O" not in fields or {"-Onone", "-Ounchecked"}.intersection(fields):
                raise ValueError(f"Expected checked -O Swift compilation for {target}")
            optimized.add(target)
    if optimized != targets:
        missing = ", ".join(sorted(targets - optimized))
        raise ValueError(f"Missing checked -O Swift compilation for {missing}")


def command(arguments, environment):
    return subprocess.check_output(list(map(str, arguments)), env=environment, text=True, timeout=30,
                                   stderr=subprocess.STDOUT).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(executable, evidence, repeats, environment):
    samples = {mode: [] for mode in WORKLOADS}
    for mode in WORKLOADS:
        for repetition in range(1, repeats + 1):
            label = f"{mode}-{repetition}"
            cpu_before = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.perf_counter_ns()
            child = subprocess.run([*NETWORK_BLOCK, str(executable), mode], env=environment,
                                   capture_output=True, text=True, timeout=90)
            wall_ns = time.perf_counter_ns() - start
            cpu_after = resource.getrusage(resource.RUSAGE_CHILDREN)
            (evidence / f"{label}.stdout").write_text(child.stdout, encoding="utf-8")
            (evidence / f"{label}.stderr").write_text(child.stderr, encoding="utf-8")
            if child.returncode != 0:
                raise ValueError(f"{label} failed with exit {child.returncode}")
            row = validate_sample(mode, json.loads(child.stdout))
            row["wholeProcessWallNanos"] = wall_ns
            row["wholeProcessCPUNanos"] = round(1_000_000_000 * (
                cpu_after.ru_utime - cpu_before.ru_utime + cpu_after.ru_stime - cpu_before.ru_stime
            ))
            samples[mode].append(row)
    return samples


def verify(evidence, repeats):
    if sys.platform != "darwin":
        raise ValueError("This performance fixture requires macOS allocation statistics and network sandboxing")
    swift, environment = swift_toolchain()
    environment = offline_git_environment(environment) | {"GIT_OPTIONAL_LOCKS": "0"}
    revision = clean_revision(ROOT, environment)
    if evidence.is_relative_to(ROOT):
        relative = evidence.relative_to(ROOT)
        ignored = subprocess.run(["git", "-C", str(ROOT), "check-ignore", "--quiet", "--", str(relative)],
                                 env=environment, timeout=10)
        if ignored.returncode:
            raise ValueError("Place performance evidence outside the source tree or in an ignored directory")
    evidence.mkdir(parents=True, exist_ok=True)
    if any(evidence.iterdir()):
        raise ValueError("Use an empty performance evidence directory")

    with tempfile.TemporaryDirectory(prefix="BlueprintRuntimePerformance-") as directory:
        root = Path(directory)
        staged = root / "source"
        staged.mkdir()
        archived = root / "source.tar"
        subprocess.run(["git", "-C", str(ROOT), "archive", "--format=tar", "-o", str(archived), revision],
                       env=environment, check=True, timeout=30)
        archive_sha = digest(archived)
        with tarfile.open(archived) as archive:
            archive.extractall(staged, filter="data")
        package = staged / "Fixtures/RuntimePerformance"
        state = root / "SwiftPM"
        environment["CLANG_MODULE_CACHE_PATH"] = str(state / "clang-modules")
        graph_command = [*NETWORK_BLOCK, *package_command(swift, package, state), "--disable-sandbox",
                         "--manifest-cache", "none", "show-dependencies", "--format", "json"]
        graph = json.loads(checked(graph_command, environment, evidence / "dependency-graph.log"))
        validate_dependencies(graph, staged)
        build = [*NETWORK_BLOCK, *package_command(swift, package, state, action="build"),
                 "--disable-sandbox", "--manifest-cache", "none", "--build-system", "native",
                 "--configuration", "release", "--disable-index-store", "--jobs", "1",
                 "--product", "RuntimePerformanceProbe", "--verbose"]
        build_start = time.perf_counter_ns()
        checked(build, environment, evidence / "release-build.log")
        build_wall = time.perf_counter_ns() - build_start
        validate_release_compilation((evidence / "release-build.log").read_text(encoding="utf-8"))
        bin_command = [part for part in build if part != "--verbose"] + ["--show-bin-path"]
        bin_path = Path(checked(bin_command, environment, evidence / "bin-path.log").decode().strip())
        if not bin_path.resolve(strict=True).is_relative_to((state / "build").resolve(strict=True)):
            raise ValueError("Expected the executable from the isolated SwiftPM state")
        executable = bin_path / "RuntimePerformanceProbe"
        deployment_target = (staged / "scripts/macos-deployment-target").read_text().strip()
        load_commands = checked([*NETWORK_BLOCK, "/usr/bin/otool", "-l", str(executable)], environment,
                                evidence / "deployment.log")
        validate_deployment(load_commands, deployment_target)
        executable_sha = digest(executable)
        samples = collect(executable, evidence, repeats, environment)

    if clean_revision(ROOT, environment) != revision:
        raise ValueError("The checkout revision changed during measurement")
    report = {
        "schemaVersion": 1,
        "status": "report-only",
        "sourceRevision": revision,
        "sourceArchiveSHA256": archive_sha,
        "hardware": {
            "model": command(["/usr/sbin/sysctl", "-n", "hw.model"], environment),
            "machine": platform.machine(),
            "logicalCPUs": int(command(["/usr/sbin/sysctl", "-n", "hw.ncpu"], environment)),
            "memoryBytes": int(command(["/usr/sbin/sysctl", "-n", "hw.memsize"], environment)),
        },
        "host": command(["/usr/bin/sw_vers"], environment),
        "swift": str(swift),
        "swiftCompiler": command([environment["SWIFT_EXEC"], "--version"], environment),
        "sdkPath": environment["SDKROOT"],
        "sdkVersion": command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], environment),
        "deploymentTarget": "macOS " + deployment_target,
        "buildMode": "SwiftPM release, checked -O",
        "buildCommand": build,
        "buildWallNanos": build_wall,
        "executableSHA256": executable_sha,
        "cacheState": "isolated build and fresh process per sample; explicit latency warm-up",
        "recording": "normal retained history with one scalar equality rule and constant answer",
        "memoryAccounting": "whole-process net live malloc-zone blocks/bytes; peak RSS includes validation",
        "samples": samples,
        "summary": summarize(samples),
        "artifacts": {item.name: digest(item) for item in sorted(evidence.iterdir())},
    }
    path = evidence / "runtime-performance.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"EVIDENCE: {path.name} SHA-256 {digest(path)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    options = parser.parse_args()
    if options.repeats < 1:
        parser.error("--repeats must be positive")
    try:
        verify(options.evidence_dir.resolve(), options.repeats)
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Runtime performance measurement failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
