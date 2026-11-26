#!/usr/bin/env python3
"""Resolve an exact tooling export and the runtime independently through local SCM."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse

from export_tooling import unpack_verified_archive
from verify_remote_install import PACKAGE_ID, REMOTE_URL, rewrite_manifest, swift_toolchain, validate_revision


TOOLING_ID = "blueprint-swift-mocking-tools"
SYNTAX_ID = "swift-syntax"
TOOLING_LOCAL = '.package(name: "BlueprintMockingTools", path: "../../Packages/Tooling")'
FIXTURES = {
    "PluginConsumer": (
        "Package.swift",
        "blueprint-mocking.json",
        "Sources/PluginDomain/Anchor.swift",
        "Sources/PluginDomain/Lookup.swift",
        "Sources/PluginMocks/Anchor.swift",
        "Sources/PluginProbe/main.swift",
    ),
    "RuntimeOnly": ("Package.swift", "Sources/RuntimeOnly/main.swift"),
}


def git(path, arguments, environment):
    return subprocess.check_output(
        ["git", "-C", str(path), *arguments], env=environment, timeout=60,
    )


def git_text(path, arguments, environment):
    return git(path, arguments, environment).decode("utf-8").strip()


def export_repository(contents, destination, repository, revision, environment):
    info = unpack_verified_archive(contents, destination, repository, revision)
    git(destination, ["init", "--quiet", "--template="], environment)
    git(destination, ["-c", "core.autocrlf=false", "add", "--all"], environment)
    timestamp = git_text(repository, ["show", "-s", "--format=%cI", revision], environment)
    ident = {
        "GIT_AUTHOR_NAME": "Blueprint Mocking",
        "GIT_AUTHOR_EMAIL": "tooling-export@example.invalid",
        "GIT_COMMITTER_NAME": "Blueprint Mocking",
        "GIT_COMMITTER_EMAIL": "tooling-export@example.invalid",
        "GIT_AUTHOR_DATE": timestamp,
        "GIT_COMMITTER_DATE": timestamp,
    }
    git(destination, [
        "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign",
        "-m", f"Verified tooling export from {revision}",
    ], environment | ident)
    return info, git_text(destination, ["rev-parse", "HEAD"], environment)


def stage_fixture(repository, revision, fixture, destination, environment, runtime_url, tooling=None):
    for relative in FIXTURES[fixture]:
        data = git(repository, ["show", f"{revision}:Fixtures/{fixture}/{relative}"], environment)
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)

    manifest = destination / "Package.swift"
    source = rewrite_manifest(manifest.read_text(encoding="utf-8"), revision)
    source = source.replace(f'"{REMOTE_URL}"', json.dumps(runtime_url, ensure_ascii=False))
    if tooling:
        if source.count(TOOLING_LOCAL) != 1 or 'package: "BlueprintMockingTools"' not in source:
            raise ValueError("Unexpected tooling dependency in the archived PluginConsumer fixture")
        tooling_url, tooling_revision = tooling
        quoted_url = json.dumps(tooling_url, ensure_ascii=False)
        source = source.replace(TOOLING_LOCAL, f'.package(url: {quoted_url}, revision: "{tooling_revision}")')
        source = source.replace('package: "BlueprintMockingTools"', f'package: "{TOOLING_ID}"')
    manifest.write_text(source, encoding="utf-8")


def package_command(swift, package, state):
    return [
        str(swift), "package", "--package-path", str(package),
        "--scratch-path", str(state / "build"),
        "--cache-path", str(state / "cache"),
        "--config-path", str(state / "configuration"),
        "--security-path", str(state / "security"),
    ]


def run(command, environment, log):
    result = subprocess.run(
        command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, check=False,
    )
    log.write_bytes(result.stderr)
    if result.returncode:
        detail = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        raise RuntimeError(f"SwiftPM exited {result.returncode}; see {log}\n{detail[-4000:]}")
    return result.stdout


def file_origin_matches(location, repository_path):
    url = urlparse(location)
    if url.scheme == "file" and url.netloc in ("", "localhost"):
        candidate = Path(unquote(url.path))
    elif not url.scheme:
        candidate = Path(location)
        if not candidate.is_absolute():
            return False
    else:
        return False
    return candidate.resolve() == repository_path.resolve()


def validate_pin(pin, revision, origin, *, version=None, original_url=None):
    if pin.get("kind") not in ("localSourceControl", "remoteSourceControl"):
        raise ValueError(f"Expected an SCM pin for {pin.get('identity')}")
    location = pin["location"]
    if not file_origin_matches(location, origin) and location != original_url:
        raise ValueError(f"Unexpected origin for {pin['identity']}: {location}")
    state = pin["state"]
    if state.get("revision") != revision or state.get("version") != version:
        raise ValueError(f"Unexpected installed state for {pin['identity']}: {state}")


def dependency_nodes(node, identities):
    dependencies = node["dependencies"]
    by_id = {dependency["identity"]: dependency for dependency in dependencies}
    if len(by_id) != len(dependencies) or set(by_id) != identities:
        raise ValueError(f"Unexpected dependencies of {node['identity']}: {sorted(by_id)}")
    return by_id


def resolve_lane(swift, package, state, evidence, lane, environment, *, mirror=None):
    command = package_command(swift, package, state)
    if mirror:
        original, offline_url = mirror
        run(command + ["config", "set-mirror", "--original", original, "--mirror", offline_url],
            environment, evidence / f"{lane}-mirror.log")
    graph_name = f"{lane}-dependency-graph.json"
    graph_data = run(command + ["--skip-update", "show-dependencies", "--format", "json"],
                     environment, evidence / f"{lane}-resolver.log")
    lock_name = f"{lane}-package-resolved.json"
    lock_data = (package / "Package.resolved").read_bytes()
    (evidence / graph_name).write_bytes(graph_data)
    (evidence / lock_name).write_bytes(lock_data)
    pins = json.loads(lock_data)["pins"]
    pin_index = {pin["identity"]: pin for pin in pins}
    if len(pins) != len(pin_index):
        raise ValueError(f"Duplicate source-control pins in {lane}")
    return json.loads(graph_data), pin_index, {
        graph_name: hashlib.sha256(graph_data).hexdigest(),
        lock_name: hashlib.sha256(lock_data).hexdigest(),
    }


def verify_installed_products(swift, tooling_node, state, evidence, environment, export_revision):
    checkout = Path(tooling_node["path"]).resolve(strict=True)
    if not checkout.is_relative_to((state / "build/checkouts").resolve()):
        raise ValueError("The tooling package did not resolve into an independent checkout")
    if git_text(checkout, ["rev-parse", "HEAD"], environment) != export_revision:
        raise ValueError("The installed tooling checkout differs from its exact SCM pin")
    command = package_command(swift, checkout, state / "manifest")
    manifest_name = "tooling-install-manifest.json"
    raw = run(command + ["dump-package"], environment, evidence / "tooling-install-manifest.log")
    (evidence / manifest_name).write_bytes(raw)
    manifest = json.loads(raw)
    products = {product["name"]: (product["targets"], product["type"]) for product in manifest["products"]}
    expected = {
        "blueprint-mocking": (["BlueprintMockingCLI"], {"executable": None}),
        "BlueprintMockingBuildPlugin": (["BlueprintMockingBuildPlugin"], {"plugin": None}),
    }
    if products != expected:
        raise ValueError(f"Unexpected tooling products in the resolved package: {products}")
    return {manifest_name: hashlib.sha256(raw).hexdigest()}


def verify(repository, revision, contents, syntax_mirror, evidence):
    validate_revision(revision)
    swift, environment = swift_toolchain()
    environment |= {"GIT_ALLOW_PROTOCOL": "file", "GIT_PROTOCOL_FROM_USER": "0"}
    if git_text(syntax_mirror, ["rev-parse", "--is-bare-repository"], environment) != "true":
        raise ValueError("The SwiftSyntax mirror must be a local bare Git repository")

    with tempfile.TemporaryDirectory(prefix="Verified Tooling Install ", dir=evidence) as temporary:
        root = Path(temporary)
        exported = root / TOOLING_ID
        info, exported_commit = export_repository(contents, exported, repository, revision, environment)
        syntax = info["compatibility"]["swiftSyntax"]
        actual_syntax = git_text(syntax_mirror, [
            "rev-parse", "--verify", "--end-of-options", f"refs/tags/{syntax['version']}^{{commit}}",
        ], environment)
        if actual_syntax != syntax["revision"]:
            raise ValueError("The prepared SwiftSyntax mirror does not contain the verified source pin")

        runtime_alias = root / PACKAGE_ID
        runtime_alias.symlink_to(repository, target_is_directory=True)
        syntax_alias = root / f"{SYNTAX_ID}.git"
        syntax_alias.symlink_to(syntax_mirror, target_is_directory=True)
        tooling_fixture = root / "Plugin Consumer"
        runtime_fixture = root / "Runtime Only Consumer"
        stage_fixture(repository, revision, "PluginConsumer", tooling_fixture, environment, str(runtime_alias),
                      tooling=(str(exported), exported_commit))
        stage_fixture(repository, revision, "RuntimeOnly", runtime_fixture, environment, str(runtime_alias))

        tooling_state = root / "Tooling State"
        graph, pins, hashes = resolve_lane(swift, tooling_fixture, tooling_state, evidence,
                                            "tooling-install", environment,
                                            mirror=(syntax["url"], str(syntax_alias)))
        nodes = dependency_nodes(graph, {PACKAGE_ID, TOOLING_ID})
        dependency_nodes(nodes[PACKAGE_ID], set())
        syntax_nodes = dependency_nodes(nodes[TOOLING_ID], {SYNTAX_ID})
        dependency_nodes(syntax_nodes[SYNTAX_ID], set())
        if not file_origin_matches(syntax_nodes[SYNTAX_ID]["url"], syntax_alias):
            raise ValueError("The resolved SwiftSyntax graph did not use the prepared local mirror")
        if set(pins) != {TOOLING_ID, PACKAGE_ID, SYNTAX_ID}:
            raise ValueError(f"Unexpected tooling pins: {sorted(pins)}")
        validate_pin(pins[PACKAGE_ID], revision, runtime_alias)
        validate_pin(pins[TOOLING_ID], exported_commit, exported)
        validate_pin(pins[SYNTAX_ID], syntax["revision"], syntax_alias,
                     version=syntax["version"], original_url=syntax["url"])
        product_hashes = verify_installed_products(
            swift, nodes[TOOLING_ID], tooling_state, evidence, environment, exported_commit,
        )
        print("PASS: exported tooling resolves by exact SCM revision with pinned SwiftSyntax", flush=True)
        print("PASS: resolved tooling exposes the executable and SwiftPM build plugin", flush=True)

        runtime, runtime_pins, runtime_hashes = resolve_lane(
            swift, runtime_fixture, root / "Runtime State", evidence, "runtime-only-install", environment,
        )
        runtime_nodes = dependency_nodes(runtime, {PACKAGE_ID})
        dependency_nodes(runtime_nodes[PACKAGE_ID], set())
        if set(runtime_pins) != {PACKAGE_ID}:
            raise ValueError(f"Unexpected runtime-only pins: {sorted(runtime_pins)}")
        validate_pin(runtime_pins[PACKAGE_ID], revision, runtime_alias)
        print("PASS: runtime-only external consumer has no transitive package dependencies", flush=True)

        report = {
            "sourceRevision": revision,
            "sourceToolingTree": git_text(repository, ["rev-parse", f"{revision}:Packages/Tooling"], environment),
            "exportCommit": exported_commit,
            "exportTree": git_text(exported, ["rev-parse", "HEAD^{tree}"], environment),
            "gitTransport": "file-only",
            "archiveSHA256": hashlib.sha256(contents).hexdigest(),
            "fixtureSwift": str(swift),
            "swiftSyntax": syntax,
            "artifacts": hashes | product_hashes | runtime_hashes,
        }
        path = evidence / "tooling-install-report.json"
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"EVIDENCE: {path.name} SHA-256 {hashlib.sha256(path.read_bytes()).hexdigest()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision", help="Exact commit underlying the tooling export")
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--swift-syntax-mirror", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        evidence = args.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "tooling-install-report.json").unlink(missing_ok=True)
        verify(args.repository.resolve(strict=True), args.revision, args.archive.read_bytes(),
               args.swift_syntax_mirror.resolve(strict=True), evidence)
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Tooling install verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
