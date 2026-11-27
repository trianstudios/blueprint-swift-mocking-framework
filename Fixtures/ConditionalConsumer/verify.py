#!/usr/bin/env python3
"""Qualify explicit domain conditions with two native SwiftPM target builds."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


FIXTURE = Path("Fixtures/ConditionalConsumer")
DOMAIN = "ConditionalDomain"
FLAG = "BLUEPRINT_DOMAIN_INT"
TEST = "GEN004_domainTargetSelectsConditionalWitness"
MARKER = "BLUEPRINT_CONDITIONAL_DOMAIN "
NEGATED_MARKER = "BLUEPRINT_NEGATED_CONDITIONAL_DOMAIN "
DEFINED_TARGET = f'.target(name: "{DOMAIN}", swiftSettings: [.define("{FLAG}")])'
UNDEFINED_TARGET = f'.target(name: "{DOMAIN}")'
MISSING_CONDITION = (
    r"BPM001: Missing compilation condition 'BLUEPRINT_DOMAIN_INT' for source module 'ConditionalDomain'\. "
    r"Supply --source-condition ConditionalDomain BLUEPRINT_DOMAIN_INT true or false\."
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def stage(repository, checkout):
    ignore = shutil.ignore_patterns(".build", ".swiftpm", "Package.resolved", "__pycache__")
    fixture = checkout / FIXTURE
    shutil.copytree(repository / FIXTURE, fixture, ignore=ignore)
    shutil.copytree(repository / "Sources", checkout / "Sources", ignore=ignore)
    shutil.copy2(repository / "Package.swift", checkout / "Package.swift")
    return fixture


def authored_swift(fixture, output):
    return {
        str(file.relative_to(fixture)): sha256(file.read_bytes())
        for base in ("Sources", "Tests") for file in (fixture / base).rglob("*.swift")
        if file != output
    }


def verify(repository, swift, tool, evidence, jobs):
    with tempfile.TemporaryDirectory(prefix="SwiftPM Domain Conditions ", dir=evidence) as directory:
        checkout = Path(directory)
        fixture = stage(repository, checkout)
        build = checkout / "Build Products"
        manifest = fixture / "Package.swift"
        source = fixture / f"Sources/{DOMAIN}/ConditionalDirectory.swift"
        output = fixture / "Sources/ConditionalDoubles/ConditionalDirectoryMock.swift"
        if output.exists():
            raise ValueError("The consumer fixture must start without generated output")
        handwritten = authored_swift(fixture, output)
        original_manifest = manifest.read_text(encoding="utf-8")
        if original_manifest.count(DEFINED_TARGET) != 1:
            raise ValueError("Expected exactly one domain target condition in the fixture manifest")

        command = [str(swift), "test", "--package-path", str(fixture), "--scratch-path", str(build),
                   "--jobs", str(jobs), "--filter", TEST]
        generation = [str(tool), "--input", source, "--module", DOMAIN,
                      "--protocol", "ConditionalDirectory", "--output", output]
        records = {}

        def run(step, arguments, *, failure=None, markers=()):
            log = evidence / f"conditional-domain-{step}.log"
            result = subprocess.run(arguments, cwd=fixture, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=240, check=False)
            log.write_bytes(result.stdout)
            text = result.stdout.decode("utf-8", errors="replace")
            status_valid = (result.returncode != 0) if failure else (result.returncode == 0)
            observed = tuple(line for line in text.splitlines() if line.startswith((MARKER, NEGATED_MARKER)))
            if not status_valid or (failure and (not re.search(failure, text) or observed)):
                raise ValueError(f"{step}: unexpected command result, see {log}")
            if markers and (observed != markers or not re.search(rf"{TEST}\(\) passed", text)):
                raise ValueError(f"{step}: expected passing native test with {markers}, see {log}")
            if authored_swift(fixture, output) != handwritten:
                raise ValueError(f"{step}: authored Swift changed")
            records[step] = {"exit": result.returncode, "log": log.name, "logSHA256": sha256(result.stdout)}
            print(f"PASS: conditional domain {step}", flush=True)

        def generate(branch, defined, output_type, negated_type):
            step = f"{branch}-generation"
            run(step, [*generation, "--source-condition", DOMAIN, FLAG, defined])
            generated = output.read_bytes()
            swift_source = generated.decode("utf-8")
            witnesses = re.findall(r"(?m)^    public func (value|inverted)\(\) -> (?:Swift\.)?(\w+) \{", swift_source)
            if (sorted(witnesses) != [("inverted", negated_type), ("value", output_type)]
                    or re.search(r"(?m)^\s*#(?:if|elseif|else|endif)\b", swift_source)):
                raise ValueError(f"{step}: expected resolved {output_type} and {negated_type} witnesses")
            copy = evidence / f"conditional-domain-{branch}.swift"
            copy.write_bytes(generated)
            records[step]["generated"] = {"path": copy.name, "sha256": sha256(generated)}
            return generated

        int_output = generate("int", "true", "Int", "String")
        run("int-consumer", command,
            markers=(f"{MARKER}Swift.Int 17", f"{NEGATED_MARKER}Swift.String selected by domain"))

        updated_manifest = original_manifest.replace(DEFINED_TARGET, UNDEFINED_TARGET, 1)
        manifest.write_text(updated_manifest, encoding="utf-8")
        stale_state = (output.read_bytes(), output.stat().st_mtime_ns)
        run("stale-witness", command,
            failure=r"type 'ConditionalDirectoryMock' does not conform to protocol 'ConditionalDirectory'")
        if (output.read_bytes(), output.stat().st_mtime_ns) != stale_state or stale_state[0] != int_output:
            raise ValueError("The native stale-witness control changed the prior output")

        string_output = generate("string", "false", "String", "Bool")
        if string_output == int_output:
            raise ValueError("Changing the domain flag did not change generated witness bytes")
        run("string-consumer", command,
            markers=(f"{MARKER}Swift.String selected by domain", f"{NEGATED_MARKER}Swift.Bool true"))

        state = (output.read_bytes(), output.stat().st_mtime_ns)
        for step, module, flag in (("missing-with-probe-context", "ConditionalProbe", FLAG),
                                   ("missing-with-wrong-domain-flag", DOMAIN, "BLUEPRINT_PROBE_FIXTURE")):
            run(step, [*generation, "--source-condition", module, flag, "true"], failure=MISSING_CONDITION)
            if (output.read_bytes(), output.stat().st_mtime_ns) != state:
                raise ValueError(f"{step}: missing domain context replaced the valid witness")
        negated_source = checkout / "ConditionalNegatedOnly.swift"
        authored_negation = (
            f"public protocol ConditionalDirectory: Swift.Sendable {{\n#if !{FLAG}\n"
            "    func inverted() -> Bool\n#else\n    func inverted() -> String\n#endif\n}\n"
        )
        negated_source.write_text(authored_negation, encoding="utf-8")
        negated_generation = [*generation[:2], negated_source, *generation[3:]]
        run("missing-negated-with-probe-context",
            [*negated_generation, "--source-condition", "ConditionalProbe", FLAG, "true"],
            failure=r"ConditionalNegatedOnly\.swift:2:6: error: " + MISSING_CONDITION)
        if (output.read_bytes(), output.stat().st_mtime_ns) != state:
            raise ValueError("Missing negated source context replaced the valid witness")
        compound = authored_negation.replace(f"!{FLAG}", f"!{FLAG} && BLUEPRINT_EXTRA")
        negated_source.write_text(compound, encoding="utf-8")
        run("reject-negated-compound", [
            *negated_generation, "--source-condition", DOMAIN, FLAG, "true",
            "--source-condition", DOMAIN, "BLUEPRINT_EXTRA", "true",
        ], failure=(r"ConditionalNegatedOnly\.swift:2:5: error: BPM001: Unsupported compilation condition\. "
                    r"Use one bare custom identifier in #if, optionally prefixed with !\."))
        if (output.read_bytes(), output.stat().st_mtime_ns) != state:
            raise ValueError("A rejected negated condition replaced the valid witness")

        if manifest.read_text(encoding="utf-8") != updated_manifest:
            raise ValueError("The manifest changed beyond the intended domain target setting")

        return {
            "lane": "explicit standalone source conditions, native SwiftPM target settings",
            "generatedRelativePath": str(output.relative_to(fixture)),
            "manifestSHA256": {"int": sha256(original_manifest.encode()), "string": sha256(updated_manifest.encode())},
            "authoredSwiftSHA256": handwritten,
            "checks": records,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    options = parser.parse_args()
    evidence = options.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    report = evidence / "conditional-domain-report.json"
    report.unlink(missing_ok=True)
    repository = Path(__file__).resolve().parents[2]
    try:
        results = verify(repository, options.swift.absolute(), options.tool.resolve(strict=True), evidence, options.jobs)
        report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Conditional domain verification failed: {error}", file=sys.stderr)
        return 1
    print(f"EVIDENCE: {report.name} SHA-256 {sha256(report.read_bytes())}")
    print("PASS: GEN004-A explicit domain conditions select native SwiftPM witnesses")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
