#!/usr/bin/env python3
"""Exercise planned external-source membership in a real SwiftPM build."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify import FIXTURE, INDEX, MOCKS, marker_line, output_state, run_probe
from verify_associated_binding import stage, write_json


MANIFEST = "blueprint-mocking.external-sources.json"


def verify(repository, swift, tool, evidence, jobs):
    target = json.loads(subprocess.check_output([str(swift), "-print-target-info"], timeout=30))
    triple = target["target"]["unversionedTriple"]
    if not triple.endswith("-apple-macosx"):
        raise ValueError(f"The prepared local artifact requires macOS, got {triple}")
    with tempfile.TemporaryDirectory(prefix="Tracked External Swift Inputs ", dir=evidence) as temporary:
        checkout = Path(temporary)
        fixture, artifacts = stage(repository, checkout, tool, triple, fixture_path=FIXTURE)
        build = checkout / "Build Products"
        command = [
            str(swift), "run", "--package-path", str(fixture), "--scratch-path", str(build),
            "--jobs", str(jobs), "--build-system", "native", "PluginProbe",
        ]
        environment = os.environ | {"GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0"}
        manifest = fixture / MANIFEST
        lookup = fixture / "Sources/PluginDomain/Lookup.swift"
        origin = f"BLUEPRINT_PLUGIN_ORIGIN PluginDomain/{lookup.name}|{lookup.name}|{marker_line(lookup.read_text())}|1"
        records = {}

        def source(path, module="PluginDomain"):
            return {"module": module, "path": path}

        def select(*sources, mode="tracked"):
            write_json(manifest, {"schemaVersion": 1, "mode": mode, "sources": list(sources)})

        def run(step, *, stamp=True, failure=None):
            before = manifest.read_bytes() if manifest.exists() else None
            label = "external-manifest-" + step
            result = run_probe(command, fixture, evidence, label, origin=origin, stamp=stamp,
                               failure=failure, env=environment)
            outputs = output_state(build, checkout)
            after = manifest.read_bytes() if manifest.exists() else None
            if after != before:
                raise ValueError(f"{step} rewrote the external source manifest")
            records[step] = result | {"outputs": outputs}
            return outputs

        baseline = run("without-manifest")
        select()
        if run("empty-manifest", stamp=None) != baseline:
            raise ValueError("An empty external manifest must preserve the baseline outputs")
        helper_name = "External Sources/New Support.swift"
        helper = fixture / helper_name
        helper.parent.mkdir()
        helper.write_text("enum OutsideTargetMembership {}\n")
        if run("unlisted-file", stamp=False) != baseline:
            raise ValueError("An unlisted external source changed the build")

        select(source(helper_name))
        added = run("listed-file-added")
        if added[MOCKS] != baseline[MOCKS] or added[INDEX]["sha256"] == baseline[INDEX]["sha256"]:
            raise ValueError("A listed external file must change the index and preserve the unchanged Swift shard")
        if run("unchanged-manifest", stamp=False) != added:
            raise ValueError("An unchanged external manifest rewrote the generated outputs")

        conflict_name = "External Sources/Conflict.swift"
        conflict = fixture / conflict_name
        conflict.write_text(lookup.read_text())
        select(source(helper_name), source(conflict_name))
        if run("listed-conflicting-declaration", failure=r"BPM001: Expected one top-level protocol PluginDomain\.Lookup[^\n]*Conflict\.swift") != added:
            raise ValueError("A listed conflicting Swift declaration replaced a valid output")

        helper.unlink()
        conflict.unlink()
        select()
        removed = run("listed-file-removed")
        if removed[MOCKS] != baseline[MOCKS] or removed[INDEX]["sha256"] != baseline[INDEX]["sha256"]:
            raise ValueError("Removing the external file and its row must restore the baseline index")

        outside = checkout / "Outside.swift"
        outside.write_text("public enum OutsidePackage {}\n")
        helper.symlink_to(outside)
        regular_name = "External Sources/Regular Support.swift"
        (fixture / regular_name).write_text("enum PlainExternalSupport {}\n")
        inside_alias = "External Sources/Internal Alias.swift"
        (fixture / inside_alias).symlink_to(fixture / regular_name)
        invalid = [
            ("linked-outside-root", [source(helper_name)], "tracked", r"external source[^\n]*outside"),
            ("symbolic-link", [source(inside_alias)], "tracked", r"external source[^\n]*(symbolic|symlink)"),
            ("target-member-duplicate", [source("Sources/PluginDomain/Lookup.swift")], "tracked",
             r"external source[^\n]*(listed|membership)"),
            ("traversal", [source("../../Outside.swift")], "tracked", r"external source[^\n]*(relative|outside|traversal)"),
            ("foreign-module", [source(regular_name, "AnotherModule")], "tracked", r"external source[^\n]*module"),
            ("prebuild", [], "prebuild", r"prebuild[^\n]*(binary|unsupported)"),
        ]
        for step, sources, mode, diagnostic in invalid:
            select(*sources, mode=mode)
            if run(step, failure=diagnostic) != removed:
                raise ValueError(f"{step} replaced an existing generated output")
        manifest.unlink()
        linked = checkout / "External Manifest.json"
        write_json(linked, {"schemaVersion": 1, "mode": "tracked", "sources": []})
        manifest.symlink_to(linked)
        if run("linked-manifest", failure=r"external source manifest[^\n]*regular file") != removed:
            raise ValueError("A linked manifest replaced an existing generated output")
        return {"hostTriple": triple, "toolArtifacts": artifacts, "checks": records}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--host-tool", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    report = verify(args.repository.resolve(), args.swift.absolute(), args.host_tool.resolve(),
                    args.evidence_dir.resolve(), args.jobs)
    write_json(args.evidence_dir / "swiftpm-external-source-manifest.json", report)
    print("PASS: tracked external Swift file membership regenerates through the SwiftPM build graph")
