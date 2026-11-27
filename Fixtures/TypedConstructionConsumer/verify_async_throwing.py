#!/usr/bin/env python3
"""Verify generated async typed constructor effects and cancellation history."""

import argparse
from functools import partial
import json
from pathlib import Path
import platform
import tempfile

from verify import run, snapshot


FIXTURE = Path(__file__).resolve().parent
check = partial(run, suite="GEN026-async-typed")
MODULE = "AsyncThrowingConstructorDomain"
PROTOCOL = "AsyncThrowingConstructionDirectory"


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", f"{platform.machine()}-apple-macosx13.0",
                "-swift-version", "6", "-parse-as-library"]
    with tempfile.TemporaryDirectory(prefix="Async Typed Construction ", dir=evidence) as directory:
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
        generated = snapshot(output)
        assert set(generated) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"
        standalone = case / "Standalone.swift"
        check([options.tool, "generate", "--input", domain, "--module", MODULE, "--protocol", PROTOCOL,
               "--output", standalone], evidence, "standalone-generation")
        witness = shard.read_text(encoding="utf-8").split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        check([options.tool, "verify-generated", *request], evidence, "verify-generated")
        inspection = json.loads(check([options.tool, "inspect", *request, "--format", "json"], evidence,
                                      "inspect-async-typed-constructor"))
        signature = f"|init(seed:Swift.Int) async throws({MODULE}.AsyncConstructionFailure)->Self|"
        endpoint = next(row for row in inspection["declarations"][0]["endpoints"] if signature in row["id"])
        assert endpoint["file"] == domain.name and endpoint["line"] == 7

        domain_library = case / f"lib{MODULE}.dylib"
        check(compiler + ["-module-name", MODULE, "-emit-module", "-emit-library", "-emit-module-path",
                          case / f"{MODULE}.swiftmodule", "-Xlinker", "-install_name", "-Xlinker",
                          f"@rpath/{domain_library.name}", domain, "-o", domain_library],
              evidence, "compile-separate-domain")
        include = ["-I", case, "-I", options.runtime_modules]
        runtime = options.runtime_library
        consumer = case / "IndependentConsumer"
        check(compiler + include + ["-Xlinker", "-rpath", "-Xlinker", case, "-Xlinker", "-rpath", "-Xlinker",
                                    runtime.parent, domain_library, runtime, shard, index,
                                    FIXTURE / "AsyncThrowingIndependentConsumer.swift", "-o", consumer],
              evidence, "compile-metatype-consumer")
        result = check([consumer], evidence, "run-metatype-consumer")
        assert "async typed construction preserves declared outcomes independently of cancellation" in result

        for variant, isolation in [
            ("ordinary", []),
            ("main-default", ["-default-isolation", "MainActor",
                              "-enable-upcoming-feature", "NonisolatedNonsendingByDefault"]),
        ]:
            check(compiler + include + isolation + ["-emit-sil", standalone, "-o", "/dev/null"],
                  evidence, "compile-isolation-" + variant)
            check(compiler + include + isolation + ["-typecheck", standalone,
                  FIXTURE / "AsyncThrowingConstructorMissingAwait.swift"],
                  evidence, "reject-missing-await-" + variant, expected=1,
                  diagnostic=r"error: [^\n]*async[^\n]*not marked with 'await'")
            check(compiler + include + isolation + ["-typecheck", standalone,
                  FIXTURE / "AsyncThrowingConstructorWrongError.swift"],
                  evidence, "reject-wrong-error-" + variant, expected=1,
                  diagnostic=r"error: [^\n]*ForeignAsyncConstructionError[^\n]*AsyncConstructionFailure")

        declarations = original.split("\n\npublic func", 1)[0] + "\n"
        for name, source in [
            ("async-failable-typed", declarations.replace("init(seed: Int)", "init?(seed: Int)")),
            ("async-untyped", declarations.replace("throws(AsyncConstructionFailure)", "throws")),
        ]:
            domain.write_text(source, encoding="utf-8")
            check(compiler + ["-typecheck", domain], evidence, "compile-control-" + name)
            check([options.tool, "generate", *request], evidence, "reject-" + name, expected=1,
                  diagnostic=r"error: BPM001: [^\n]*ordinary direct Sendable")
            assert snapshot(output) == generated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
