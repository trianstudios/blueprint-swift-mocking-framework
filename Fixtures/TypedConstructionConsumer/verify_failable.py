#!/usr/bin/env python3
"""Exercise generated failable constructors through an independent protocol metatype."""

import argparse
from functools import partial
import json
from pathlib import Path
import platform
import signal
import tempfile

from verify import run, snapshot


FIXTURE = Path(__file__).resolve().parent
fixture_run = partial(run, suite="GEN026-failable")


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    target = f"{architecture}-apple-macosx13.0"
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", target, "-swift-version", "6"]
    with tempfile.TemporaryDirectory(prefix="Failable Construction ", dir=evidence) as directory:
        case = Path(directory)
        domain = case / "FailableConstructorDomain.swift"
        original = (FIXTURE / domain.name).read_text(encoding="utf-8")
        domain.write_text(original, encoding="utf-8")
        config = case / "blueprint-mocking.json"
        config.write_text(json.dumps({
            "schemaVersion": 1,
            "selections": [{"module": "FailableConstructorDomain", "type": "FailableConstructionDirectory", "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = case / "generated"
        request = ["--config", config, "--output", output, "--input-set-id", "a026",
                   "--source", "FailableConstructorDomain", domain]
        fixture_run([options.tool, "generate", *request], evidence, "configured-generation")
        before = snapshot(output)
        assert set(before) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"
        standalone = case / "Standalone.swift"
        fixture_run([options.tool, "generate", "--input", domain, "--module", "FailableConstructorDomain",
                     "--protocol", "FailableConstructionDirectory", "--output", standalone],
                    evidence, "standalone-generation")
        witness = shard.read_text(encoding="utf-8").split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        fixture_run([options.tool, "verify-generated", *request], evidence, "verify-generated")
        inspection = json.loads(fixture_run([options.tool, "inspect", *request, "--format", "json"],
                                            evidence, "inspect-failable-constructor"))
        endpoint = next(endpoint for endpoint in inspection["declarations"][0]["endpoints"]
                        if "|init?(seed:Swift.Int)->Self?" in endpoint["id"])
        assert endpoint["file"] == domain.name and endpoint["line"] == 2
        assert snapshot(output) == before

        flags = ["-parse-as-library", "-module-cache-path", case / "module-cache"]
        fixture_run(compiler + flags + ["-module-name", "FailableConstructorDomain", "-emit-module", "-emit-library",
                                        "-emit-module-path", case / "FailableConstructorDomain.swiftmodule",
                                        "-Xlinker", "-install_name", "-Xlinker", "@rpath/libFailableConstructorDomain.dylib",
                                        domain, "-o", case / "libFailableConstructorDomain.dylib"],
                    evidence, "compile-separate-domain")
        runtime = options.runtime_library
        app = case / "IndependentConsumer"
        fixture_run(compiler + flags + ["-I", case, "-I", options.runtime_modules, "-L", case, "-lFailableConstructorDomain",
                                        "-Xlinker", "-rpath", "-Xlinker", case,
                                        "-Xlinker", "-rpath", "-Xlinker", runtime.parent, runtime,
                                        shard, index, FIXTURE / "FailableIndependentConsumer.swift", "-o", app],
                    evidence, "compile-metatype-consumer")
        result = fixture_run([app], evidence, "run-metatype-consumer")
        assert "failable construction returns configured nil and links only successful instances" in result
        assert "Failable constructor issue:" not in (evidence / "run-metatype-consumer.log").read_text(encoding="utf-8")
        fixture_run(compiler + flags + ["-typecheck", "-default-isolation", "MainActor",
                                        "-I", case, "-I", options.runtime_modules, standalone],
                    evidence, "typecheck-main-default")

        fatal_status = -int(signal.SIGTRAP if architecture == "arm64" else signal.SIGILL)
        for mode, diagnostic in [
            ("unscoped", r"Missing type-level mock scope"),
            ("unbound-detached", r"Missing type-level mock scope"),
            ("stale", r"stale type-level mock scope"),
            ("finished", r"finished mock session"),
        ]:
            signature = r"init\?\(seed:Swift.Int\)"
            fixture_run([app, mode], evidence, "reject-runtime-" + mode, expected=fatal_status,
                        diagnostic=rf"{diagnostic}[^\n]*{signature}|{signature}[^\n]*{diagnostic}")

        protocol = original.split("\n\n", 1)[0] + "\n"
        for name, source in [
            ("wrong-label", protocol.replace("init?(seed: Int)", "init?(value: Int)")),
            ("async-failable", protocol.replace("init?(seed: Int)", "init?(seed: Int) async")),
            ("typed-throwing-failable", "public enum Failure: Error { case unavailable }\n" +
             protocol.replace("init?(seed: Int)", "init?(seed: Int) throws(Failure)")),
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
