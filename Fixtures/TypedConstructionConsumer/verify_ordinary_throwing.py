#!/usr/bin/env python3
"""Verify plain-throws constructor errors, context diagnostics and construction history."""

import argparse
from functools import partial
import json
from pathlib import Path
import platform
import re
import tempfile

from verify import run, snapshot


FIXTURE = Path(__file__).resolve().parent
MODULE = "OrdinaryThrowingConstructorDomain"
PROTOCOL = "OrdinaryThrowingConstructionDirectory"
SIGNATURE = "|init(seed:Swift.Int) throws->Self|"
check = partial(run, suite="GEN026-ordinary-throws")


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", f"{platform.machine()}-apple-macosx13.0",
                "-swift-version", "6", "-parse-as-library"]
    with tempfile.TemporaryDirectory(prefix="Ordinary Throwing Construction ", dir=evidence) as directory:
        case = Path(directory)
        compiler += ["-module-cache-path", case / "module-cache"]
        domain = case / f"{MODULE}.swift"
        original = (FIXTURE / domain.name).read_text(encoding="utf-8")
        domain.write_text(original, encoding="utf-8")
        config = case / "blueprint-mocking.json"
        config.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": MODULE, "type": PROTOCOL, "kind": "protocol"}
        ]}) + "\n", encoding="utf-8")
        output = case / "generated"
        request = ["--config", config, "--output", output, "--input-set-id", "a026", "--source", MODULE, domain]
        check([options.tool, "generate", *request], evidence, "configured-generation")
        before = snapshot(output)
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"
        standalone = case / "Standalone.swift"
        check([options.tool, "generate", "--input", domain, "--module", MODULE, "--protocol", PROTOCOL,
               "--output", standalone], evidence, "standalone-generation")
        witness = shard.read_text(encoding="utf-8").split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        assert "public convenience init(seed: Swift.Int) throws {" in witness
        check([options.tool, "verify-generated", *request], evidence, "verify-generated")
        inspection = json.loads(check([options.tool, "inspect", *request, "--format", "json"], evidence, "inspect-constructor"))
        endpoint = next(row for row in inspection["declarations"][0]["endpoints"] if SIGNATURE in row["id"])
        assert endpoint["file"] == domain.name and endpoint["line"] == 2

        library = case / f"lib{MODULE}.dylib"
        check(compiler + ["-module-name", MODULE, "-emit-module", "-emit-library", "-emit-module-path",
                          case / f"{MODULE}.swiftmodule", "-Xlinker", "-install_name", "-Xlinker",
                          f"@rpath/{library.name}", domain, "-o", library], evidence, "compile-separate-domain")
        include = ["-I", case, "-I", options.runtime_modules]
        runtime = options.runtime_library
        app = case / "IndependentConsumer"
        check(compiler + include + ["-Xlinker", "-rpath", "-Xlinker", case, "-Xlinker", "-rpath", "-Xlinker",
                                    runtime.parent, library, runtime, shard, index,
                                    FIXTURE / "OrdinaryThrowingIndependentConsumer.swift", "-o", app],
              evidence, "compile-metatype-consumer")
        result = check([app], evidence, "run-metatype-consumer")
        assert "ordinary throwing construction preserves configured errors and reports rejected scopes" in result
        diagnostic = (r"(?m)^OrdinaryThrowingConstructorDomain\.swift:2:\d+: error: BlueprintMocking: "
                      r"Missing type-level mock scope for [^\n]*init\(seed:Swift.Int\) throws")
        for mode in ("unbound", "unbound-detached"):
            label = "report-" + mode
            result = check([app, mode], evidence, label, diagnostic=diagnostic)
            assert "missing ordinary throwing scope reports once and throws" in result
            assert len(re.findall(diagnostic, (evidence / f"{label}.log").read_text(encoding="utf-8"))) == 1
        check(compiler + include + ["-default-isolation", "MainActor", "-emit-sil", standalone, "-o", "/dev/null"],
              evidence, "compile-main-default")

        protocol = original.split("\n\n", 1)[0] + "\n"
        for label, unsupported in (
            ("async-untyped", protocol.replace("init(seed: Int) throws", "init(seed: Int) async throws")),
            ("failable-throwing", protocol.replace("init(seed: Int) throws", "init?(seed: Int) throws")),
        ):
            domain.write_text(unsupported, encoding="utf-8")
            check(compiler + ["-typecheck", domain], evidence, "compile-control-" + label)
            check([options.tool, "generate", *request], evidence, "reject-" + label, expected=1,
                  diagnostic=r"error: BPM001: [^\n]*ordinary direct Sendable")
            assert snapshot(output) == before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
