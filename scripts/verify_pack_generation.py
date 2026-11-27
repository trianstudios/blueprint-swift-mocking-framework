#!/usr/bin/env python3
"""Check the standalone value-pack provider route and fail-closed publication."""
import argparse
import re
import subprocess
import tempfile
from pathlib import Path


def verify(tool, original, evidence):
    evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="blueprint-pack-provider-") as temporary:
        root = Path(temporary)
        source = root / original.name
        output = root / "PackProviderDirectoryMock.swift"
        suite = original.read_text()
        source.write_text(suite)
        base = [tool.resolve(), "--input", source, "--module", "ConsumerDomain",
                "--protocol", "PackProviderDirectory", "--output", output]
        provider = ["--generic-provider", "echo(_:)"]

        def run(name, options):
            result = subprocess.run([str(arg) for arg in base + options], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, timeout=20)
            (evidence / f"{name}.log").write_text(result.stdout)
            return result

        generated = run("pack-provider-generation", provider)
        if generated.returncode != 0:
            raise RuntimeError(f"Pack generation exited {generated.returncode}:\n{generated.stdout}")
        previous = output.read_bytes()
        repeated = run("pack-provider-generation-repeat", provider)
        if repeated.returncode != 0 or output.read_bytes() != previous:
            raise RuntimeError("Repeated pack generation did not reproduce the same bytes")
        timestamp = output.stat().st_mtime_ns
        (evidence / output.name).write_bytes(previous)

        unsupported = "Pack providers require one direct synchronous nonthrowing Sendable value pack"
        cases = [
            ("unselected", suite, [], "Value pack methods require --generic-provider 'echo(_:)'"),
            ("finite", suite, ["--specialize-method", "echo(_:)=Int"],
             "Value pack methods require --generic-provider; finite pack specializations are unsupported"),
            ("result-shape", suite.replace("-> (repeat each Element)", "-> (repeat (each Element, Int))"),
             provider, unsupported),
            ("throwing", suite.replace("-> (repeat each Element)", "throws -> (repeat each Element)"),
             provider, unsupported),
            ("two-packs", suite.replace("<each Element: Sendable>", "<each Element: Sendable, each Second: Sendable>"),
             provider, unsupported),
            ("stronger-constraint", suite.replace("each Element: Sendable", "each Element: Hashable & Sendable"),
             provider, "Pack providers require an inline Sendable element constraint"),
        ]
        for name, fixture, options, message in cases:
            if name not in {"unselected", "finite"} and fixture == suite:
                raise RuntimeError(f"The {name} mutation did not match the input")
            source.write_text(fixture)
            result = run(f"pack-provider-reject-{name}", options)
            expected = rf"(?m)^{re.escape(str(source))}:2:\d+: error: BPM001: {re.escape(message)}"
            if result.returncode != 1 or not re.search(expected, result.stdout):
                raise RuntimeError(f"{name} did not identify the declaration:\n{result.stdout}")
            if output.read_bytes() != previous or output.stat().st_mtime_ns != timestamp:
                raise RuntimeError(f"{name} replaced the previous generated file")
    print("PASS: pack provider generation is repeatable and rejects unsupported shapes before publication")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] /
                        "Fixtures/ProtocolConsumer/Sources/ConsumerDomain/PackProviderDirectory.swift")
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    verify(args.tool, args.source, args.evidence_dir)
