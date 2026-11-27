#!/usr/bin/env python3
"""Verify configured generic method specialization through the SwiftPM build plugin."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify import CONFIGURATION, INDEX, MOCKS, output_state, run_probe, swift_files
from verify_associated_binding import digest, stage, write_json


FIXTURE = Path("Fixtures/PluginConsumer/GenericMethod")
OPTIONS = "genericMethodSpecializations"
TRANSFORM = "transform(_:)"
AUXILIARY = "auxiliary(_:)"
ORIGIN = "BLUEPRINT_CONFIGURED_GENERIC_METHODS"
PROBE_ORIGIN = f"{ORIGIN} Swift.Int Swift.String"
REPORT = "swiftpm-plugin-generic-method-report.json"


def check_auxiliary(shard, type_name):
    source = shard.read_text(encoding="utf-8")
    qualified = f"Swift.{type_name}"
    signature = f"public func auxiliary(_ matcher: Matcher<{qualified}>, as _: ({qualified}).Type"
    if source.count(signature) != 2 or source.count("public func auxiliary(_ matcher:") != 2:
        raise ValueError(f"The generated auxiliary setup and verification must both use {qualified}")


def verify(repository, swift, tool, evidence, jobs):
    target = json.loads(subprocess.check_output([str(swift), "-print-target-info"], timeout=30))
    triple = target["target"]["unversionedTriple"]
    if not triple.endswith("-apple-macosx"):
        raise ValueError(f"The local plugin artifact probe requires a macOS toolchain, got {triple}")

    with tempfile.TemporaryDirectory(prefix="Configured Generic Methods With Spaces ", dir=evidence) as directory:
        checkout = Path(directory)
        fixture, artifacts = stage(repository, checkout, tool, triple, fixture_path=FIXTURE)
        build = checkout / "Build Products"
        command = [
            "nice", "-n", "10", str(swift), "run", "--package-path", str(fixture),
            "--scratch-path", str(build), "--jobs", str(jobs), "GenericMethodPluginProbe",
        ]
        environment = os.environ | {"GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0"}
        authored = swift_files(fixture / "Sources")
        config = fixture / CONFIGURATION
        original = json.loads(config.read_bytes())
        selected, = original["selections"]
        records = {}

        def set_options(options):
            write_json(config, original | {"selections": [selected | {OPTIONS: options}]})

        def run(step, *, auxiliary=None, stamp=True, failure=None):
            result = run_probe(
                command, fixture, evidence, f"generic-method-{step}",
                origin=PROBE_ORIGIN if failure is None else None, stamp=stamp, failure=failure, env=environment,
            )
            if failure and ORIGIN in (evidence / result["log"]).read_text(encoding="utf-8", errors="replace"):
                raise ValueError(f"{step}: a rejected build ran its consumer probe")
            outputs = output_state(build, checkout)
            if auxiliary:
                check_auxiliary(build / outputs[MOCKS]["path"], auxiliary)
            records[step] = result | {"configurationSHA256": digest(config.read_bytes()), "outputs": outputs}
            return outputs

        initial = run("first-int", auxiliary="Int")
        updated_options = [
            option | {"type": "String"} if option["selector"] == AUXILIARY else option
            for option in selected[OPTIONS]
        ]
        set_options(updated_options)
        updated_configuration = config.read_bytes()
        updated = run("config-only-string", auxiliary="String")
        for name in (MOCKS, INDEX):
            if initial[name]["path"] != updated[name]["path"]:
                raise ValueError(f"A config edit moved {name}")
            if initial[name]["sha256"] == updated[name]["sha256"]:
                raise ValueError(f"A changed specialization did not update {name}")
        if run("unchanged-string", auxiliary="String", stamp=False) != updated:
            raise ValueError("An unchanged configuration rewrote the generated outputs")

        set_options(updated_options + [{"selector": TRANSFORM, "type": "Swift.Int"}])
        duplicate = r"BPM001: Duplicate generic method specialization 'Swift.Int' for 'transform\(_:\)'"
        if run("duplicate-normalized-type", failure=duplicate) != updated:
            raise ValueError("A duplicate specialization changed the last valid outputs")

        set_options([option for option in updated_options if option["selector"] != AUXILIARY])
        missing = (r"BPM001: Generic methods require explicit specialization for 'auxiliary\(_:\)' "
                   r"using --specialize-method or genericMethodSpecializations")
        if run("missing-method", failure=missing) != updated:
            raise ValueError("A missing specialization changed the last valid outputs")

        config.write_bytes(updated_configuration)
        if run("recover", auxiliary="String", stamp=None) != updated:
            raise ValueError("Restoring valid configuration rewrote the last valid outputs")
        if swift_files(fixture / "Sources") != authored:
            raise ValueError("Configured method qualification changed authored Swift")
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
    parser.add_argument("--jobs", type=int, default=1)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    swift = options.swift.absolute()
    tool = options.host_tool.resolve(strict=True)
    if not os.access(tool, os.X_OK) or not os.access(swift, os.X_OK):
        parser.error("--swift and --host-tool must point to executable files")
    if options.jobs < 1:
        parser.error("--jobs must be positive")
    evidence = options.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    report = evidence / REPORT
    report.unlink(missing_ok=True)
    write_json(report, verify(repository, swift, tool, evidence, options.jobs))
    print(f"EVIDENCE: {report.name} SHA-256 {digest(report.read_bytes())}")
    print("PASS: GEN010 configured generic methods compiled and ran through the SwiftPM build plugin")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
