#!/usr/bin/env python3
"""Qualify SwiftSyntax package constraints with SwiftPM's local, file-only solver."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from verify_remote_install import LOCAL_DEPENDENCY, swift_toolchain
from verify_tooling_install import (
    FIXTURES,
    TOOLING_LOCAL,
    dependency_nodes,
    file_origin_matches,
    git,
    git_text,
    package_command,
    resolve_lane,
    run,
    validate_pin,
)


SWIFT_SYNTAX_URL = "https://github.com/swiftlang/swift-syntax.git"
COMPATIBLE = "600.0.1"
INCOMPATIBLE = "601.0.0"
RUNTIME_PRODUCT = '.product(name: "BluepringMockingFramework", package: "BluepringMockingFramework")'
SYNTAX_PRODUCT = '.product(name: "SwiftSyntax", package: "swift-syntax")'
MIRROR_MANIFEST = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "swift-syntax",
    products: [
        .library(name: "SwiftSyntax", targets: ["SwiftSyntax"]),
        .library(name: "SwiftParser", targets: ["SwiftParser"]),
    ],
    targets: [
        .target(name: "SwiftSyntax"),
        .target(name: "SwiftParser", dependencies: ["SwiftSyntax"]),
    ]
)
"""


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_syntax_mirror(root, environment):
    seed = root / "SwiftSyntax Solver Seed"
    seed.mkdir()
    git(seed, ["init", "--quiet", "--template="], environment)
    (seed / "Package.swift").write_text(MIRROR_MANIFEST, encoding="utf-8")
    syntax = seed / "Sources/SwiftSyntax"
    parser = seed / "Sources/SwiftParser"
    syntax.mkdir(parents=True)
    parser.mkdir(parents=True)
    (parser / "Anchor.swift").write_text("public enum SolverParserAnchor {}\n", encoding="utf-8")
    pins = {}
    for version in (COMPATIBLE, INCOMPATIBLE):
        (syntax / "Anchor.swift").write_text(
            f'public let solverFixtureVersion = "{version}"\n', encoding="utf-8",
        )
        git(seed, ["-c", "core.autocrlf=false", "add", "--all"], environment)
        git(seed, [
            "-c", "user.name=Blueprint Mocking", "-c", "user.email=solver-fixture@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", f"Solver fixture {version}",
        ], environment | {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"})
        git(seed, ["tag", version], environment)
        pins[version] = git_text(seed, ["rev-parse", "HEAD"], environment)
    mirror = root / "swift-syntax.git"
    git(root, ["clone", "--bare", "--quiet", str(seed), str(mirror)], environment)
    return mirror, pins


def local_dependency(name, path):
    return f'.package(name: "{name}", path: {json.dumps(str(path), ensure_ascii=False)})'


def stage_fixture(repository, destination, *, plugin, syntax_version):
    fixture = "PluginConsumer" if plugin else "RuntimeOnly"
    for relative in FIXTURES[fixture]:
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes((repository / "Fixtures" / fixture / relative).read_bytes())

    manifest = destination / "Package.swift"
    source = manifest.read_text(encoding="utf-8")
    if source.count(LOCAL_DEPENDENCY) != 1 or RUNTIME_PRODUCT not in source:
        raise ValueError(f"Unexpected runtime interop fixture {fixture}")
    syntax = f'.package(url: "{SWIFT_SYNTAX_URL}", exact: "{syntax_version}")'
    source = source.replace(
        LOCAL_DEPENDENCY, local_dependency("BluepringMockingFramework", repository) + ",\n        " + syntax,
    ).replace(RUNTIME_PRODUCT, RUNTIME_PRODUCT + ",\n            " + SYNTAX_PRODUCT, 1)
    if plugin:
        if source.count(TOOLING_LOCAL) != 1:
            raise ValueError("Unexpected tooling manifest dependency in the plugin fixture")
        source = source.replace(TOOLING_LOCAL, local_dependency("BlueprintMockingTools", repository / "Packages/Tooling"))
    manifest.write_text(source, encoding="utf-8")


def check_resolved(swift, package, state, evidence, lane, env, mirror, revision, version, repository, *, plugin):
    graph, pins, hashes = resolve_lane(
        swift, package, state, evidence, lane, env, mirror=(SWIFT_SYNTAX_URL, str(mirror)),
    )
    runtime = repository.name.lower()
    roots = {runtime, "swift-syntax", "tooling"} if plugin else {runtime, "swift-syntax"}
    dependencies = dependency_nodes(graph, roots)
    dependency_nodes(dependencies[runtime], set())
    syntax = dependencies["swift-syntax"]
    dependency_nodes(syntax, set())
    if syntax["version"] != version or not file_origin_matches(syntax["url"], mirror):
        raise ValueError(f"{lane}: SwiftPM selected an unexpected SwiftSyntax source or version")
    if plugin:
        child = dependency_nodes(dependencies["tooling"], {"swift-syntax"})["swift-syntax"]
        dependency_nodes(child, set())
        if child["version"] != version or not file_origin_matches(child["url"], mirror):
            raise ValueError(f"{lane}: the tooling package did not share the selected parser pin")
    if set(pins) != {"swift-syntax"}:
        raise ValueError(f"{lane}: expected only a SwiftSyntax source-control pin")
    validate_pin(pins["swift-syntax"], revision, mirror, version=version, original_url=SWIFT_SYNTAX_URL)
    log = evidence / f"{lane}-resolver.log"
    return hashes | {log.name: file_hash(log)}


def check_conflict(swift, package, state, evidence, lane, environment, mirror):
    command = package_command(swift, package, state)
    run(command + ["config", "set-mirror", "--original", SWIFT_SYNTAX_URL, "--mirror", str(mirror)],
        environment, evidence / f"{lane}-mirror.log")
    result = subprocess.run(
        command + ["--skip-update", "show-dependencies", "--format", "json"],
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False,
    )
    log = evidence / f"{lane}-resolver.log"
    log.write_bytes(result.stdout)
    output = result.stdout.decode("utf-8", errors="replace")
    if (result.returncode == 0 or not re.search(r"version solving failed|dependencies could not be resolved", output, re.I)
            or not all(word in output for word in ("swift-syntax", "tooling", COMPATIBLE, INCOMPATIBLE))):
        raise ValueError(f"Expected a real SwiftPM solver conflict naming both SwiftSyntax versions; see {log}\n{output}")
    return {log.name: file_hash(log)}


def verify(repository, evidence):
    swift, environment = swift_toolchain()
    environment |= {"GIT_ALLOW_PROTOCOL": "file", "GIT_PROTOCOL_FROM_USER": "0"}
    with tempfile.TemporaryDirectory(prefix="SwiftPM Solver Probe ", dir=evidence) as directory:
        root = Path(directory)
        mirror, revisions = make_syntax_mirror(root, environment)
        artifacts = {}
        lanes = (
            ("runtime-with-601", False, INCOMPATIBLE, True),
            ("plugin-conflicts-with-601", True, INCOMPATIBLE, False),
            ("plugin-with-600", True, COMPATIBLE, True),
        )
        for lane, plugin, version, accepted in lanes:
            consumer = root / lane
            stage_fixture(repository, consumer, plugin=plugin, syntax_version=version)
            state = root / f"{lane}-state"
            if accepted:
                artifacts |= check_resolved(
                    swift, consumer, state, evidence, lane, environment, mirror, revisions[version], version,
                    repository, plugin=plugin,
                )
            else:
                artifacts |= check_conflict(swift, consumer, state, evidence, lane, environment, mirror)
            print(f"PASS: SwiftPM compatibility {lane}", flush=True)
        return {
            "test": "SwiftPM local SemVer fixture, dependency solver only",
            "gitTransport": "file-only",
            "swift": str(swift),
            "runtimeManifestSHA256": file_hash(repository / "Package.swift"),
            "toolingManifestSHA256": file_hash(repository / "Packages/Tooling/Package.swift"),
            "disposableSwiftSyntaxTagCommits": revisions,
            "artifacts": artifacts,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    try:
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        report = evidence / "swiftpm-compatibility-report.json"
        report.unlink(missing_ok=True)
        results = verify(options.repository.resolve(strict=True), evidence)
        report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"EVIDENCE: {report.name} SHA-256 {file_hash(report)}")
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"SwiftPM compatibility verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
