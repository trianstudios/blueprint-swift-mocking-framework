#!/usr/bin/env python3
"""Exercise configured bindings through SwiftPM using the selected bundled-Xcode tool."""

import argparse
from base64 import b64decode
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
PUBLICATION_FAULT = "BLUEPRINT_TEST_PUBLICATION_CHECKPOINT"
PUBLICATION_CHECKPOINTS = ("after-shard", "after-index")
JOURNAL = ".blueprint-mocking-transaction.json"
DIRTY_INDEX = b'#error("Blueprint Mocking: interrupted output publication. Rerun generation to recover.")\n'
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


def verify(repository, swift, tool, evidence, jobs, *, publication_checkpoint=None, first_publication=False):
    if first_publication:
        publication_checkpoint = "after-shard"
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
            "--jobs", str(jobs),
        ]
        if publication_checkpoint:
            # The native build system forwards the test fault flag to the plugin executable.
            command.extend(["--build-system", "native"])
        command.append("AssociatedPluginProbe")
        authored = swift_files(fixture / "Sources")
        config = fixture / CONFIGURATION
        original = json.loads(config.read_bytes())
        records = {}
        environment = None
        if publication_checkpoint:
            environment = os.environ.copy()
            environment.pop(PUBLICATION_FAULT, None)
            environment.pop("BLUEPRINT_TEST_ABORT_AFTER_SHARD", None)

        recovery_lanes = {
            "after-shard": "publication-recovery",
            "after-index": "publication-recovery-after-index",
        }
        lane = ("first-publication-recovery" if first_publication
                else recovery_lanes.get(publication_checkpoint, "associated-binding"))

        def set_bindings(*types):
            selected, = original["selections"]
            bindings = [{"name": "Element", "type": type_name} for type_name in types]
            write_json(config, original | {"selections": [selected | {"associatedTypeBindings": bindings}]})

        def run(step, type_name=None, *, stamp=True, failure=None, env=environment):
            label = f"{lane}-{step}"
            origin = f"{ORIGIN}Swift.{type_name}" if type_name else None
            result = run_probe(command, fixture, evidence, label, origin=origin, stamp=stamp, failure=failure, env=env)
            if failure and ORIGIN in (evidence / result["log"]).read_text(encoding="utf-8", errors="replace"):
                raise ValueError(f"{step}: a rejected build ran its consumer probe")
            outputs = output_state(build, checkout)
            records[step] = result | {"outputs": outputs}
            return outputs

        if first_publication:
            if build.exists() or any(path.name in (MOCKS, INDEX, JOURNAL) for path in fixture.rglob("*")):
                raise ValueError("The first build must start without generated outputs or a recovery journal")
            initial = {}
            binding = "String"
        else:
            initial = run("first-string", "String")
            if publication_checkpoint and (build / initial[INDEX]["path"]).with_name(JOURNAL).exists():
                raise ValueError("The passing baseline left a recovery journal")
            set_bindings("Int")
            binding = "Int"

        binding_label = binding.lower()
        if publication_checkpoint:
            edited_config = config.read_bytes()
            diagnostic = f"DX013 fixture: interrupted at {publication_checkpoint}"
            interrupted_step = f"interrupted-{binding_label}"
            interrupted = run(
                interrupted_step, failure=diagnostic,
                env=environment | {PUBLICATION_FAULT: publication_checkpoint},
            )
            fault_log = (evidence / records[interrupted_step]["log"]).read_text(encoding="utf-8")
            if fault_log.splitlines().count(diagnostic) != 1:
                raise ValueError("The failed SwiftPM build did not report its exact interruption checkpoint")
            if initial:
                if any(interrupted[name]["path"] != initial[name]["path"] for name in (MOCKS, INDEX)):
                    raise ValueError("The interrupted build moved generated outputs")
                if interrupted[MOCKS]["sha256"] == initial[MOCKS]["sha256"]:
                    raise ValueError("The interrupted build did not publish the changed shard")
            index_path = build / interrupted[INDEX]["path"]
            shard_path = build / interrupted[MOCKS]["path"]
            journal = index_path.with_name(JOURNAL)
            if not journal.is_file():
                raise ValueError("The interrupted build did not retain a recovery journal")
            journal_bytes = journal.read_bytes()
            transaction = json.loads(journal_bytes)
            if first_publication and any(transaction["previous"].get(name) is not None for name in ("shard", "index")):
                raise ValueError("A first publication must record both previous outputs as absent")
            staged = transaction["next"]
            next_shard, next_index = (b64decode(staged[key], validate=True) for key in ("shard", "index"))
            expected_index = DIRTY_INDEX if publication_checkpoint == "after-shard" else next_index
            if shard_path.read_bytes() != next_shard or index_path.read_bytes() != expected_index:
                raise ValueError("The interrupted outputs did not match the checkpoint's publication state")
            retained_index = "dirty-index.swift" if publication_checkpoint == "after-shard" else "complete-index.swift"
            for name, contents in ((retained_index, expected_index), ("journal.json", journal_bytes)):
                artifact = f"swiftpm-{lane}-{name}"
                (evidence / artifact).write_bytes(contents)
                artifacts[artifact] = digest(contents)

        update_step = f"retry-{binding_label}" if publication_checkpoint else "config-only-int"
        updated = run(update_step, binding)
        if initial and any(initial[name]["sha256"] == updated[name]["sha256"] for name in (MOCKS, INDEX)):
            raise ValueError("Changing only the concrete type must update both generated outputs")
        if run(f"unchanged-{binding_label}", binding, stamp=False) != updated:
            raise ValueError("An unchanged configuration rewrote the generated outputs")

        if publication_checkpoint:
            if journal.exists() or DIRTY_INDEX == index_path.read_bytes() or config.read_bytes() != edited_config:
                raise ValueError("The recovered build changed its authored configuration or retained incomplete output")
            if any(updated[name]["path"] != interrupted[name]["path"] for name in (MOCKS, INDEX)):
                raise ValueError("The recovered build moved generated outputs")
            if shard_path.read_bytes() != next_shard or index_path.read_bytes() != next_index:
                raise ValueError("Recovery did not publish the complete output pair")
            if publication_checkpoint == "after-index" and updated != interrupted:
                raise ValueError("Recovery rewrote the already complete output pair")
        else:
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
            **({"buildSystem": "native", "interruptionCheckpoint": publication_checkpoint,
                "retryConfigurationSHA256": digest(edited_config)} if publication_checkpoint else {}),
            **({"initialGeneratedOutputs": initial} if first_publication else {}),
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--host-tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    recovery = parser.add_mutually_exclusive_group()
    recovery.add_argument("--publication-recovery", dest="publication_checkpoint", action="store_const",
                          const="after-shard", help="Exercise the after-shard publication recovery checkpoint")
    recovery.add_argument("--publication-recovery-checkpoint", dest="publication_checkpoint",
                          choices=PUBLICATION_CHECKPOINTS,
                          help="Interrupt a fault-instrumented host tool, then retry in the same build")
    recovery.add_argument("--first-publication-recovery", action="store_true",
                          help="Interrupt the first build after its shard is written, then retry in the same build")
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    evidence = options.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    tool = options.host_tool.resolve(strict=True)
    swift = options.swift.absolute()
    if not os.access(tool, os.X_OK) or not os.access(swift, os.X_OK):
        parser.error("--swift and --host-tool must point to executable files")
    report_name = {
        "after-shard": "swiftpm-publication-recovery-report.json",
        "after-index": "swiftpm-publication-recovery-after-index-report.json",
    }.get(options.publication_checkpoint, "swiftpm-plugin-associated-binding-report.json")
    if options.first_publication_recovery:
        report_name = "swiftpm-first-publication-recovery-report.json"
    report = evidence / report_name
    report.unlink(missing_ok=True)
    write_json(report, verify(
        repository, swift, tool, evidence, options.jobs,
        publication_checkpoint=options.publication_checkpoint, first_publication=options.first_publication_recovery,
    ))
    print(f"EVIDENCE: {report.name} SHA-256 {digest(report.read_bytes())}")
    if options.first_publication_recovery:
        print("PASS: DX013 SwiftPM recovered its interrupted first publication")
    elif options.publication_checkpoint:
        print("PASS: DX013 SwiftPM rejected interrupted publication and ran the recovered pair")
    else:
        print("PASS: GEN008 configured binding compiled and ran through the SwiftPM build plugin")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
