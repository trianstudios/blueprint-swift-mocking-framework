#!/usr/bin/env python3
"""Check the runtime marker in real generated Swift witnesses."""

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


RUNTIME = "BlueprintMocking"
DOMAIN = "SchemaProbeDomain"
DOUBLES = "SchemaProbeDoubles"
MARKER = "BlueprintRuntimeSchemaV1"
OTHER_MARKER = "BlueprintRuntimeSchemaV999"
REPORT = "runtime-schema-report.json"

PROTOCOLS = """\
public enum SchemaProbeFailure: Error {
    case offline
}

public protocol SchemaInstanceProbe: Sendable {
    func load(key: String) async throws(SchemaProbeFailure) -> String
}

public protocol SchemaStaticProbe: Sendable {
    static subscript(_ index: Int) -> Int { get set }
}
"""

LOOKALIKE = """\
import BlueprintMocking

enum BlueprintRuntimeSchemaV1 {
    static func reportMissingTypeScope(_ endpoint: EndpointID, source: SourceLocation) -> String {
        "consumer-local schema lookalike"
    }
}
"""

DIAGNOSTIC = re.compile(
    r"(?m)^(?:.*[/\\])?(Schema(?:Instance|Static)ProbeMock\.swift):"
    r"(\d+):\d+:\s+error:\s+([^\r\n]+)"
)
MISSING_SYMBOL = re.compile(
    r"\b(?:no type|no member|has no|cannot find|not a member|does not (?:have|contain))\b"
)


def repository_root():
    for directory in Path(__file__).resolve().parents:
        if (directory / "Sources" / RUNTIME).is_dir() and (directory / "Package.swift").is_file():
            return directory
    raise ValueError("Cannot locate the Blueprint Mocking checkout")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_other_runtime(sources, directory):
    directory.mkdir()
    result = []
    marker = re.compile(rb"\b" + MARKER.encode() + rb"\b")
    declarations = 0
    for source in sources:
        original = source.read_bytes()
        declarations += original.count(f"public enum {MARKER} ".encode())
        revised = marker.sub(OTHER_MARKER.encode(), original)
        if revised == original:
            result.append(source)
        else:
            copy = directory / source.name
            copy.write_bytes(revised)
            result.append(copy)
    if declarations != 1:
        raise ValueError(f"Expected one public runtime declaration of {MARKER}, found {declarations}")
    return result


def marker_line(mock):
    matches = [
        index for index, line in enumerate(mock.read_text().splitlines(), start=1)
        if "__schema" in line and MARKER in line
    ]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one emitted runtime marker in {mock.name}")
    return matches[0]


def verify(repository, tool, swiftc, sdk, evidence):
    checks = {}
    floor = (repository / "scripts/macos-deployment-target").read_text().strip()
    target = f"{platform.machine()}-apple-macos{floor}"
    compiler = [swiftc, "-swift-version", "6", "-target", target, "-sdk", sdk]
    runtime_sources = sorted((repository / "Sources" / RUNTIME).glob("*.swift"))

    def run(label, arguments, cwd, *, require_success=True):
        stdout_path = evidence / f"runtime-schema-{label}.stdout"
        stderr_path = evidence / f"runtime-schema-{label}.stderr"
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            result = subprocess.run(
                arguments, cwd=cwd, stdout=stdout, stderr=stderr, check=False, timeout=180,
            )
        checks[label] = {
            "exit": result.returncode,
            "stdout": stdout_path.name,
            "stdoutSHA256": digest(stdout_path),
            "stderr": stderr_path.name,
            "stderrSHA256": digest(stderr_path),
        }
        if require_success and result.returncode != 0:
            raise ValueError(f"{label} exited {result.returncode}. See {stderr_path}")
        return result.returncode, stderr_path.read_text(encoding="utf-8", errors="replace")

    with tempfile.TemporaryDirectory(prefix="Generated Runtime Schema ", dir=evidence) as temporary:
        scratch = Path(temporary)
        source = scratch / "SchemaProbes.swift"
        source.write_text(PROTOCOLS, encoding="utf-8")
        lookalike = scratch / "ConsumerSchemaLookalike.swift"
        lookalike.write_text(LOOKALIKE, encoding="utf-8")
        mocks = []
        for protocol in ("SchemaInstanceProbe", "SchemaStaticProbe"):
            mock = scratch / f"{protocol}Mock.swift"
            run(f"generate-{protocol}", [
                tool, "--input", source, "--module", DOMAIN, "--protocol", protocol, "--output", mock,
            ], scratch)
            mocks.append(mock)
        if source.read_text(encoding="utf-8") != PROTOCOLS:
            raise ValueError("Generation changed the authored protocol source")

        def emit_module(label, module, directory, sources):
            directory.mkdir()
            artifact = directory / f"{module}.swiftmodule"
            run(label, [
                *compiler, "-parse-as-library", "-emit-module", "-module-name", module,
                "-emit-module-path", artifact, *sources,
            ], scratch)
            if not artifact.is_file() or not artifact.stat().st_size:
                raise ValueError(f"{label} did not produce a Swift module")
            return artifact

        compatible = emit_module("build-compatible-runtime", RUNTIME, scratch / "Compatible Runtime", runtime_sources)
        incompatible_sources = prepare_other_runtime(runtime_sources, scratch / "Changed Runtime Sources")
        incompatible = emit_module(
            "build-incompatible-runtime", RUNTIME, scratch / "Incompatible Runtime", incompatible_sources,
        )
        domain = emit_module("build-domain", DOMAIN, scratch / "Domain", [source])

        def typecheck(label, runtime_module, sources, *, require_success=True):
            return run(label, [
                *compiler, "-typecheck", "-module-name", DOUBLES,
                "-I", domain.parent, "-I", runtime_module.parent, *sources, lookalike,
            ], scratch, require_success=require_success)

        typecheck("compatible-consumer", compatible, mocks)
        diagnosed = {}
        # A Swift compiler may stop after the first primary file fails type checking.
        for mock in mocks:
            exit_code, diagnostic = typecheck(
                f"incompatible-{mock.stem}", incompatible, [mock], require_success=False,
            )
            if exit_code == 0:
                raise ValueError(f"The incompatible runtime unexpectedly accepted {mock.name} with the schema lookalike")
            if exit_code < 0:
                raise ValueError(f"The incompatible consumer compiler terminated by signal {-exit_code}")

            line = marker_line(mock)
            message = next((
                message for name, position, message in DIAGNOSTIC.findall(diagnostic)
                if name == mock.name and int(position) == line
                and MARKER in message and RUNTIME in message and MISSING_SYMBOL.search(message)
            ), None)
            if message is None:
                raise ValueError(f"{mock.name}:{line} did not report the missing {RUNTIME}.{MARKER} in generated code")
            diagnosed[f"{mock.name}:{line}"] = message

        static_source = mocks[1].read_text(encoding="utf-8")
        fallbacks = [line for line in static_source.splitlines() if ".reportMissingTypeScope(" in line]
        if len(fallbacks) != 2 or any(
            f"{RUNTIME}.{MARKER}.reportMissingTypeScope(" not in line for line in fallbacks
        ):
            raise ValueError("The static getter and setter do not use the runtime module's missing-scope reporter")

        return {
            "status": "passed",
            "target": target,
            "sdk": str(sdk),
            "runtimeModule": RUNTIME,
            "compatibleMarker": MARKER,
            "incompatibleMarker": OTHER_MARKER,
            "generatorSHA256": digest(tool),
            "generatedSHA256": {mock.name: digest(mock) for mock in mocks},
            "missingRuntimeMarkerDiagnostics": diagnosed,
            "checks": checks,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--swiftc", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    options = parser.parse_args()
    tool, swiftc, sdk = (path.absolute() for path in (options.tool, options.swiftc, options.sdk))
    if not all(path.is_file() and os.access(path, os.X_OK) for path in (tool, swiftc)) or not sdk.is_dir():
        parser.error("--tool and --swiftc must be executable files and --sdk must be a directory")
    evidence = options.evidence_dir.resolve()
    try:
        evidence.mkdir(parents=True, exist_ok=True)
        report_path = evidence / REPORT
        report_path.unlink(missing_ok=True)
        report = verify(repository_root(), tool, swiftc, sdk, evidence)
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Runtime schema verification failed: {error}", file=sys.stderr)
        return 1
    print(f"EVIDENCE: {REPORT} SHA-256 {digest(report_path)}")
    print("PASS: GEN007 emitted witnesses reject an incompatible runtime despite a consumer-local schema lookalike")
    return 0


if __name__ == "__main__":
    sys.exit(main())
