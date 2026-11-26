#!/usr/bin/env python3
"""Exercise configured bindings through SwiftPM using the selected bundled-Xcode tool."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from verify import CONFIGURATION, INDEX, MOCKS, output_state, run_probe, swift_files


FIXTURE = Path("Fixtures/PluginConsumer/AssociatedBinding")
PLUGIN = "BlueprintMockingBuildPlugin"
TOOL = "BlueprintMockingCLI"
TOOLING = Path("Packages/Tooling")
ORIGIN = "BLUEPRINT_CONFIGURED_BINDING "
TOOL_PROVIDER = """// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueprintMockingTools",
    platforms: [.macOS(.v13)],
    products: [.plugin(name: "BlueprintMockingBuildPlugin", targets: ["BlueprintMockingBuildPlugin"])],
    targets: [
        .binaryTarget(name: "BlueprintMockingCLI", path: "BlueprintMockingCLI.artifactbundle"),
        .plugin(name: "BlueprintMockingBuildPlugin", capability: .buildTool(), dependencies: ["BlueprintMockingCLI"]),
    ],
    swiftLanguageModes: [.v6]
)
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def stage(repository, checkout, tool, target):
    ignore = shutil.ignore_patterns(".build", ".swiftpm", "Package.resolved", "__pycache__")
    fixture = checkout / FIXTURE
    shutil.copytree(repository / FIXTURE, fixture, ignore=ignore)
    shutil.copytree(repository / "Sources", checkout / "Sources", ignore=ignore)
    shutil.copy2(repository / "Package.swift", checkout / "Package.swift")

    provider = checkout / TOOLING
    plugin = Path("Plugins") / PLUGIN / "plugin.swift"
    (provider / plugin).parent.mkdir(parents=True)
    shutil.copy2(repository / TOOLING / plugin, provider / plugin)
    (provider / "Package.swift").write_text(TOOL_PROVIDER, encoding="utf-8")
    bundle = provider / f"{TOOL}.artifactbundle"
    executable = bundle / "macos" / TOOL
    executable.parent.mkdir(parents=True)
    shutil.copy2(tool, executable)
    manifest = {
        "schemaVersion": "1.0",
        "artifacts": {TOOL: {
            "type": "executable", "version": "1.0.0",
            "variants": [{"path": f"macos/{TOOL}", "supportedTriples": [target]}],
        }},
    }
    write_json(bundle / "info.json", manifest)
    return fixture, {
        "productionPluginSHA256": digest((provider / plugin).read_bytes()),
        "hostExecutableSHA256": digest(executable.read_bytes()),
        "bundleMetadataSHA256": digest((bundle / "info.json").read_bytes()),
    }


def verify(repository, swift, tool, evidence, jobs):
    target = json.loads(subprocess.check_output([str(swift), "-print-target-info"], timeout=30))
    triple = target["target"]["unversionedTriple"]
    if not triple.endswith("-apple-macosx"):
        raise ValueError(f"The local plugin artifact probe requires a macOS toolchain, got {triple}")
    with tempfile.TemporaryDirectory(prefix="Configured Binding With Spaces ", dir=evidence) as directory:
        checkout = Path(directory)
        fixture, artifacts = stage(repository, checkout, tool, triple)
        build = checkout / "Build Products"
        command = [
            str(swift), "run", "--package-path", str(fixture), "--scratch-path", str(build),
            "--jobs", str(jobs), "AssociatedPluginProbe",
        ]
        authored = swift_files(fixture / "Sources")
        config = fixture / CONFIGURATION
        original = json.loads(config.read_bytes())
        records = {}

        def set_bindings(*types):
            selected, = original["selections"]
            bindings = [{"name": "Element", "type": type_name} for type_name in types]
            write_json(config, original | {"selections": [selected | {"associatedTypeBindings": bindings}]})

        def run(step, type_name=None, *, stamp=True, failure=None):
            label = f"associated-binding-{step}"
            origin = f"{ORIGIN}Swift.{type_name}" if type_name else None
            result = run_probe(command, fixture, evidence, label, origin=origin, stamp=stamp, failure=failure)
            if failure and ORIGIN in (evidence / result["log"]).read_text(encoding="utf-8", errors="replace"):
                raise ValueError(f"{step}: a rejected build ran its consumer probe")
            outputs = output_state(build, checkout)
            records[step] = result | {"outputs": outputs}
            return outputs

        initial = run("first-string", "String")
        set_bindings("Int")
        updated = run("config-only-int", "Int")
        if any(initial[name]["sha256"] == updated[name]["sha256"] for name in (MOCKS, INDEX)):
            raise ValueError("Changing only the concrete type must update both generated outputs")
        if run("unchanged-int", "Int", stamp=False) != updated:
            raise ValueError("An unchanged configuration rewrote the generated outputs")

        set_bindings("Int", "String")
        diagnostic = r"BPM001: Conflicting explicit bindings for associated type 'Element'"
        for step in ("conflict", "conflict-retry"):
            if run(step, failure=diagnostic) != updated:
                raise ValueError(f"{step}: a conflicting configuration changed the last valid outputs")

        set_bindings("Int")
        if run("recover", "Int", stamp=None) != updated:
            raise ValueError("Restoring the valid configuration did not preserve the last valid outputs")
        if swift_files(fixture / "Sources") != authored:
            raise ValueError("Configured binding qualification changed authored Swift")
        return {
            "toolLane": "bundled-Xcode executable, production plugin scheduling, local artifactbundle",
            "compilerVersion": target["compilerVersion"],
            "hostTriple": triple,
            "artifacts": artifacts,
            "authoredSwift": {str(path): digest(data) for path, data in sorted(authored.items())},
            "checks": records,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--host-tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    evidence = options.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    tool = options.host_tool.resolve(strict=True)
    swift = options.swift.absolute()
    if not os.access(tool, os.X_OK) or not os.access(swift, os.X_OK):
        parser.error("--swift and --host-tool must point to executable files")
    report = evidence / "swiftpm-plugin-associated-binding-report.json"
    report.unlink(missing_ok=True)
    write_json(report, verify(repository, swift, tool, evidence, options.jobs))
    print(f"EVIDENCE: {report.name} SHA-256 {digest(report.read_bytes())}")
    print("PASS: GEN008 configured binding compiled and ran through the SwiftPM build plugin")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
