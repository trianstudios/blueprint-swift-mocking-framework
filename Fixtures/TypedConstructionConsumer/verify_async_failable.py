#!/usr/bin/env python3
"""Exercise generated async failable constructors through an independent protocol metatype."""

import argparse
from functools import partial
import json
from pathlib import Path
import platform
import signal
import tempfile

from verify import run, snapshot


FIXTURE = Path(__file__).resolve().parent
fixture_run = partial(run, suite="GEN026-async-failable")


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    target = f"{architecture}-apple-macosx13.0"
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", target, "-swift-version", "6"]
    with tempfile.TemporaryDirectory(prefix="Async Failable Construction ", dir=evidence) as directory:
        case = Path(directory)
        domain = case / "AsyncFailableConstructorDomain.swift"
        original = (FIXTURE / domain.name).read_text(encoding="utf-8")
        domain.write_text(original, encoding="utf-8")
        config = case / "blueprint-mocking.json"
        config.write_text(json.dumps({
            "schemaVersion": 1,
            "selections": [{"module": "AsyncFailableConstructorDomain", "type": "AsyncFailableConstructionDirectory", "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = case / "generated"
        request = ["--config", config, "--output", output, "--input-set-id", "a026",
                   "--source", "AsyncFailableConstructorDomain", domain]
        fixture_run([options.tool, "generate", *request], evidence, "configured-generation")
        before = snapshot(output)
        assert set(before) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"
        standalone = case / "Standalone.swift"
        fixture_run([options.tool, "generate", "--input", domain, "--module", "AsyncFailableConstructorDomain",
                     "--protocol", "AsyncFailableConstructionDirectory", "--output", standalone],
                    evidence, "standalone-generation")
        witness = shard.read_text(encoding="utf-8").split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        fixture_run([options.tool, "verify-generated", *request], evidence, "verify-generated")
        inspection = json.loads(fixture_run([options.tool, "inspect", *request, "--format", "json"],
                                            evidence, "inspect-async-failable-constructor"))
        endpoint = next(endpoint for endpoint in inspection["declarations"][0]["endpoints"]
                        if "|init?(seed:Swift.Int) async->Self?|" in endpoint["id"])
        assert endpoint["file"] == domain.name and endpoint["line"] == 2
        assert snapshot(output) == before

        flags = ["-parse-as-library", "-module-cache-path", case / "module-cache"]
        fixture_run(compiler + flags + ["-module-name", "AsyncFailableConstructorDomain", "-emit-module", "-emit-library",
                                        "-emit-module-path", case / "AsyncFailableConstructorDomain.swiftmodule",
                                        "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAsyncFailableConstructorDomain.dylib",
                                        domain, "-o", case / "libAsyncFailableConstructorDomain.dylib"],
                    evidence, "compile-separate-domain")
        runtime = options.runtime_library
        app = case / "IndependentConsumer"
        fixture_run(compiler + flags + ["-I", case, "-I", options.runtime_modules, "-L", case, "-lAsyncFailableConstructorDomain",
                                        "-Xlinker", "-rpath", "-Xlinker", case,
                                        "-Xlinker", "-rpath", "-Xlinker", runtime.parent, runtime,
                                        shard, index, FIXTURE / "AsyncFailableIndependentConsumer.swift", "-o", app],
                    evidence, "compile-metatype-consumer")
        result = fixture_run([app], evidence, "run-metatype-consumer")
        assert "async failable construction records completed nil and attached success despite cancellation" in result
        assert "Async failable constructor issue:" not in (evidence / "run-metatype-consumer.log").read_text(encoding="utf-8")
        fixture_run(compiler + flags + ["-default-isolation", "MainActor", "-enable-upcoming-feature",
                                        "NonisolatedNonsendingByDefault", "-I", case, "-I", options.runtime_modules,
                                        "-emit-sil", standalone, "-o", "/dev/null"],
                    evidence, "compile-main-default")

        fatal_status = -int(signal.SIGTRAP if architecture == "arm64" else signal.SIGILL)
        fixture_run([app, "unscoped"], evidence, "reject-runtime-unscoped", expected=fatal_status,
                    diagnostic=r"Missing type-level mock scope[^\n]*init\?\(seed:Swift.Int\) async")

        protocol = original.split("\n\n", 1)[0] + "\n"
        for name, source in [
            ("async-failable-throwing", protocol.replace("init?(seed: Int) async", "init?(seed: Int) async throws")),
            ("async-failable-typed-throwing", "public enum Failure: Error { case unavailable }\n" +
             protocol.replace("init?(seed: Int) async", "init?(seed: Int) async throws(Failure)")),
        ]:
            domain.write_text(source, encoding="utf-8")
            fixture_run(compiler + flags + ["-typecheck", domain], evidence, "compile-control-" + name)
            fixture_run([options.tool, "generate", *request], evidence, "reject-" + name, expected=1,
                        diagnostic=r"error: BPM001: [^\n]*ordinary direct Sendable")
            assert snapshot(output) == before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
