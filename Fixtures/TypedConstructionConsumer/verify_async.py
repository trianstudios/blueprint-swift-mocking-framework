#!/usr/bin/env python3
"""Exercise generated async constructors through an independent protocol metatype."""

import argparse
from functools import partial
import json
from pathlib import Path
import platform
import signal
import tempfile

from verify import run, snapshot


FIXTURE = Path(__file__).resolve().parent
fixture_run = partial(run, suite="GEN026-async")


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    target = f"{architecture}-apple-macosx13.0"
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", target, "-swift-version", "6"]
    with tempfile.TemporaryDirectory(prefix="Async Construction ", dir=evidence) as directory:
        case = Path(directory)
        domain = case / "AsyncConstructorDomain.swift"
        original = (FIXTURE / domain.name).read_text(encoding="utf-8")
        domain.write_text(original, encoding="utf-8")
        config = case / "blueprint-mocking.json"
        config.write_text(json.dumps({
            "schemaVersion": 1,
            "selections": [{"module": "AsyncConstructorDomain", "type": "AsyncConstructionDirectory", "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = case / "generated"
        request = ["--config", config, "--output", output, "--input-set-id", "a026",
                   "--source", "AsyncConstructorDomain", domain]
        fixture_run([options.tool, "generate", *request], evidence, "configured-generation")
        before = snapshot(output)
        assert set(before) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"
        standalone = case / "Standalone.swift"
        fixture_run([options.tool, "generate", "--input", domain, "--module", "AsyncConstructorDomain",
                     "--protocol", "AsyncConstructionDirectory", "--output", standalone],
                    evidence, "standalone-generation")
        witness = shard.read_text(encoding="utf-8").split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        fixture_run([options.tool, "verify-generated", *request], evidence, "verify-generated")
        inspection = json.loads(fixture_run([options.tool, "inspect", *request, "--format", "json"],
                                            evidence, "inspect-async-constructor"))
        endpoint = next(endpoint for endpoint in inspection["declarations"][0]["endpoints"]
                        if "|init(seed:Swift.Int) async->Self" in endpoint["id"])
        assert endpoint["file"] == domain.name and endpoint["line"] == 2
        assert snapshot(output) == before

        flags = ["-parse-as-library", "-module-cache-path", case / "module-cache"]
        fixture_run(compiler + flags + ["-module-name", "AsyncConstructorDomain", "-emit-module", "-emit-library",
                                        "-emit-module-path", case / "AsyncConstructorDomain.swiftmodule",
                                        "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAsyncConstructorDomain.dylib",
                                        domain, "-o", case / "libAsyncConstructorDomain.dylib"],
                    evidence, "compile-separate-domain")
        runtime = options.runtime_library
        app = case / "IndependentConsumer"
        fixture_run(compiler + flags + ["-I", case, "-I", options.runtime_modules, "-L", case, "-lAsyncConstructorDomain",
                                        "-Xlinker", "-rpath", "-Xlinker", case,
                                        "-Xlinker", "-rpath", "-Xlinker", runtime.parent, runtime,
                                        shard, index, FIXTURE / "AsyncIndependentConsumer.swift", "-o", app],
                    evidence, "compile-metatype-consumer")
        result = fixture_run([app], evidence, "run-metatype-consumer")
        assert "async construction stays active across suspension and links only after initialization" in result
        assert "Async constructor issue:" not in (evidence / "run-metatype-consumer.log").read_text(encoding="utf-8")
        for variant, isolation in [
            ("ordinary", []),
            ("main-default", ["-default-isolation", "MainActor",
                              "-enable-upcoming-feature", "NonisolatedNonsendingByDefault"]),
        ]:
            include = ["-I", case, "-I", options.runtime_modules]
            fixture_run(compiler + flags + isolation + include +
                        ["-emit-sil", standalone, "-o", "/dev/null"],
                        evidence, "compile-isolation-" + variant)
            fixture_run(compiler + flags + isolation + include +
                        ["-typecheck", standalone, FIXTURE / "AsyncConstructorMissingAwait.swift"],
                        evidence, "reject-missing-await-" + variant, expected=1,
                        diagnostic=r"error: [^\n]*async[^\n]*not marked with 'await'")

        fatal_status = -int(signal.SIGTRAP if architecture == "arm64" else signal.SIGILL)
        for mode, diagnostic in [
            ("unscoped", r"Missing type-level mock scope"),
            ("unbound-detached", r"Missing type-level mock scope"),
            ("stale", r"stale type-level mock scope"),
            ("finished", r"finished mock session"),
        ]:
            signature = r"init\(seed:Swift.Int\) async"
            fixture_run([app, mode], evidence, "reject-runtime-" + mode, expected=fatal_status,
                        diagnostic=rf"{diagnostic}[^\n]*{signature}|{signature}[^\n]*{diagnostic}")

        protocol = original.split("\n\n", 1)[0] + "\n"
        for name, source in [
            ("wrong-label", protocol.replace("init(seed: Int) async", "init(value: Int) async")),
            ("async-failable", protocol.replace("init(seed: Int) async", "init?(seed: Int) async")),
            ("async-typed-throwing", "public enum Failure: Error { case unavailable }\n" +
             protocol.replace("init(seed: Int) async", "init(seed: Int) async throws(Failure)")),
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
