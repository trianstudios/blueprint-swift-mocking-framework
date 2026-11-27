#!/usr/bin/env python3
"""Exercise exact typed constructor errors and success-only instance links."""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile


FIXTURE = Path(__file__).resolve().parent


def run(command, evidence, label, *, expected=0, diagnostic=None, suite="GEN026-typed"):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=30,
                            env={**os.environ, "SWIFT_BACKTRACE": "enable=no"})
    (evidence / f"{label}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    accepted = result.returncode != 0 if expected is None else result.returncode == expected
    if not accepted or diagnostic and not re.search(diagnostic, result.stderr):
        raise RuntimeError(f"{label}: got exit {result.returncode}\n{result.stdout}{result.stderr}")
    print(f"PASS: {suite} {label}", flush=True)
    return result.stdout


def snapshot(output):
    return {file.name: (file.stat().st_mtime_ns, file.stat().st_ino, file.read_bytes())
            for file in output.iterdir()}


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    target = f"{platform.machine()}-apple-macosx13.0"
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", target, "-swift-version", "6"]
    with tempfile.TemporaryDirectory(prefix="Typed Construction ", dir=evidence) as directory:
        case = Path(directory)
        domain = case / "TypedConstructorDomain.swift"
        original = (FIXTURE / domain.name).read_text(encoding="utf-8")
        domain.write_text(original, encoding="utf-8")
        config = case / "blueprint-mocking.json"
        config.write_text(json.dumps({
            "schemaVersion": 1,
            "selections": [{"module": "TypedConstructorDomain", "type": "TypedConstructionDirectory", "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = case / "generated"
        configured = ["--config", config, "--output", output, "--input-set-id", "a026",
                      "--source", "TypedConstructorDomain", domain]
        run([options.tool, "generate", *configured], evidence, "configured-generation")
        before = snapshot(output)
        assert set(before) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"
        standalone = case / "Standalone.swift"
        run([options.tool, "generate", "--input", domain, "--module", "TypedConstructorDomain", "--protocol",
             "TypedConstructionDirectory", "--output", standalone], evidence, "standalone-generation")
        witness = shard.read_text(encoding="utf-8").split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        run([options.tool, "verify-generated", *configured], evidence, "verify-generated")
        inspection = json.loads(run([options.tool, "inspect", *configured, "--format", "json"],
                                    evidence, "inspect-typed-constructor"))
        endpoint = next(endpoint for endpoint in inspection["declarations"][0]["endpoints"]
                        if "|init(seed:Swift.Int) throws(TypedConstructorDomain.ConstructionFailure)" in endpoint["id"])
        assert endpoint["file"] == domain.name and endpoint["line"] == 6
        assert snapshot(output) == before

        flags = ["-parse-as-library", "-module-cache-path", case / "module-cache"]
        run(compiler + flags + ["-module-name", "TypedConstructorDomain", "-emit-module", "-emit-library",
                               "-emit-module-path", case / "TypedConstructorDomain.swiftmodule",
                               "-Xlinker", "-install_name", "-Xlinker", "@rpath/libTypedConstructorDomain.dylib",
                               domain, "-o", case / "libTypedConstructorDomain.dylib"], evidence, "compile-separate-domain")
        runtime_library = options.runtime_library
        app = case / "IndependentConsumer"
        run(compiler + flags + ["-I", case, "-I", options.runtime_modules, "-L", case, "-lTypedConstructorDomain",
                               "-Xlinker", "-rpath", "-Xlinker", case,
                               "-Xlinker", "-rpath", "-Xlinker", runtime_library.parent, runtime_library,
                               shard, index, FIXTURE / "IndependentConsumer.swift", "-o", app],
            evidence, "compile-metatype-consumer")
        result = run([app], evidence, "run-metatype-consumer")
        assert "records exact failure and attaches only successful instances" in result
        fatal_status = -int(signal.SIGTRAP if platform.machine() == "arm64" else signal.SIGILL)
        for mode, diagnostic in [
            ("unscoped", r"Missing type-level mock scope"),
            ("stale", r"stale type-level mock scope"),
            ("finished", r"finished mock session"),
        ]:
            run([app, mode], evidence, "reject-runtime-" + mode, expected=fatal_status,
                diagnostic=rf"{diagnostic}[^\n]*init\(seed:Swift.Int\)|init\(seed:Swift.Int\)[^\n]*{diagnostic}")

        for name, isolation in [("ordinary", []), ("main-default", ["-default-isolation", "MainActor"])]:
            run(compiler + flags + ["-typecheck", *isolation, "-I", case, "-I", options.runtime_modules, standalone],
                evidence, "typecheck-" + name)
            run(compiler + flags + ["-typecheck", *isolation, "-I", case, "-I", options.runtime_modules,
                                   standalone, FIXTURE / "WrongConstructionError.swift"],
                evidence, "reject-wrong-error-" + name, expected=1,
                diagnostic=r"error: [^\n]*ForeignConstructionError[^\n]*ConstructionFailure")

        declarations = original.split("\n\npublic func createTypedDirectory", 1)[0] + "\n"
        for name, source, diagnostic in [
            ("untyped-wrong-label", declarations.replace("init(seed: Int) throws(ConstructionFailure)",
                                                           "init(value: Int) throws"),
             "ordinary direct Sendable"),
            ("failable", declarations.replace("init(seed: Int)", "init?(seed: Int)"), "ordinary direct Sendable"),
            ("async-wrong-label", declarations.replace("init(seed: Int) throws(ConstructionFailure)",
                                                       "init(value: Int) async throws(ConstructionFailure)"),
             "ordinary direct Sendable"),
            ("alias", declarations.replace("public protocol", "public typealias Alias = ConstructionFailure\n\npublic protocol")
                                  .replace("throws(ConstructionFailure)", "throws(Alias)"), "direct Swift.Error conformance"),
        ]:
            domain.write_text(source, encoding="utf-8")
            run(compiler + flags + ["-typecheck", domain], evidence, "compile-control-" + name)
            run([options.tool, "generate", *configured], evidence, "reject-" + name, expected=1,
                diagnostic=rf"error: BPM001: [^\n]*{diagnostic}")
            assert snapshot(output) == before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
