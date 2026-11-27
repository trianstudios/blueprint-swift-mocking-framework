#!/usr/bin/env python3
"""Verify generated scoped infallible constructors through a protocol metatype."""

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


def run(command, evidence, label, *, expected=0, diagnostic=None):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=30,
                            env={**os.environ, "SWIFT_BACKTRACE": "enable=no"})
    (evidence / f"{label}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    status_ok = result.returncode != 0 if expected is None else result.returncode == expected
    if not status_ok or diagnostic and not re.search(diagnostic, result.stderr):
        raise RuntimeError(f"{label}: got exit {result.returncode}\n{result.stdout}{result.stderr}")
    print(f"PASS: GEN026 {label}", flush=True)
    return result.stdout


def snapshot(output):
    return {file.name: (file.stat().st_mtime_ns, file.stat().st_ino, file.read_bytes())
            for file in output.iterdir()}


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    target = f"{platform.machine()}-apple-macosx13.0"
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", target, "-swift-version", "6"]
    with tempfile.TemporaryDirectory(prefix="Construction Consumer ", dir=evidence) as directory:
        case = Path(directory)
        domain = case / "ConstructorDomain.swift"
        original = (FIXTURE / domain.name).read_text(encoding="utf-8")
        domain.write_text(original, encoding="utf-8")
        config = case / "blueprint-mocking.json"
        config.write_text(json.dumps({
            "schemaVersion": 1,
            "selections": [{"module": "ConstructorDomain", "type": "ConstructionDirectory", "kind": "protocol"}],
        }) + "\n", encoding="utf-8")
        output = case / "generated"
        configured = ["--config", config, "--output", output, "--input-set-id", "a026",
                      "--source", "ConstructorDomain", domain]
        run([options.tool, "generate", *configured], evidence, "configured-generation")
        before = snapshot(output)
        assert set(before) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        shard = (output / "BlueprintMocks.generated.swift").read_text(encoding="utf-8")
        index = output / "BlueprintMockingIndex.generated.swift"

        standalone = case / "Standalone.swift"
        run([options.tool, "generate", "--input", domain, "--module", "ConstructorDomain", "--protocol",
             "ConstructionDirectory", "--output", standalone], evidence, "standalone-generation")
        witness = shard.split("\n", 1)[1].rsplit("\nenum BlueprintMockingShard_", 1)[0]
        assert witness.rstrip("\n") == standalone.read_text(encoding="utf-8").rstrip("\n")
        run([options.tool, "verify-generated", *configured], evidence, "verify-generated")
        inspection = json.loads(run([options.tool, "inspect", *configured, "--format", "json"],
                                    evidence, "inspect-constructor"))
        attempt = next(endpoint for endpoint in inspection["declarations"][0]["endpoints"]
                       if "|init(seed:Swift.Int)" in endpoint["id"])
        assert attempt["file"] == domain.name and attempt["line"] == 2
        assert snapshot(output) == before

        runtime_library = options.runtime_library
        run(compiler + ["-parse-as-library", "-module-cache-path", case / "module-cache",
                        "-module-name", "ConstructorDomain", "-emit-module", "-emit-library",
                        "-emit-module-path", case / "ConstructorDomain.swiftmodule",
                        "-Xlinker", "-install_name", "-Xlinker", "@rpath/libConstructorDomain.dylib",
                        domain, "-o", case / "libConstructorDomain.dylib"], evidence, "compile-separate-domain")
        app = case / "IndependentConsumer"
        run(compiler + ["-parse-as-library", "-module-cache-path", case / "module-cache", "-I", case,
                        "-I", options.runtime_modules, "-L", case, "-lConstructorDomain",
                        "-Xlinker", "-rpath", "-Xlinker", case,
                        "-Xlinker", "-rpath", "-Xlinker", runtime_library.parent, runtime_library,
                        output / "BlueprintMocks.generated.swift", index, FIXTURE / "IndependentConsumer.swift",
                        "-o", app], evidence, "compile-metatype-consumer")
        run(compiler + ["-typecheck", "-default-isolation", "MainActor", "-I", case,
                        "-I", options.runtime_modules, output / "BlueprintMocks.generated.swift", index],
            evidence, "compile-main-actor-default-witness")
        twice = case / "CompleteTwice.swift"
        twice.write_text("""import BlueprintMocking

func finishTwice(_ construction: consuming MockConstructionAttempt) {
    construction.complete()
    construction.complete()
}
""", encoding="utf-8")
        run(compiler + ["-I", options.runtime_modules, "-emit-sil", "-o", os.devnull, twice],
            evidence, "reject-double-construction-completion", expected=1,
            diagnostic=r"'construction' consumed more than once")
        result = run([app], evidence, "run-metatype-consumer")
        assert "attempts attach to the exact constructed instances" in result
        fatal_status = -int(signal.SIGTRAP if platform.machine() == "arm64" else signal.SIGILL)
        for mode, diagnostic in [
            ("unscoped", r"Missing type-level mock scope"),
            ("unbound-detached", r"Missing type-level mock scope"),
            ("stale", r"stale type-level mock scope"),
            ("finished", r"finished mock session"),
        ]:
            run([app, mode], evidence, "reject-runtime-" + mode, expected=fatal_status,
                diagnostic=rf"{diagnostic}[^\n]*init\(seed:Swift.Int\)|init\(seed:Swift.Int\)[^\n]*{diagnostic}")

        protocol = original.split("\n\n", 1)[0] + "\n"
        for name, source, diagnostic in [
            ("wrong-failable-label", protocol.replace("init(seed: Int)", "init?(value: Int)"), "ordinary direct Sendable"),
            ("throwing-wrong-label", protocol.replace("init(seed: Int)", "init(value: Int) throws"), "ordinary direct Sendable"),
            ("wrong-async-label", protocol.replace("init(seed: Int)", "init(value: Int) async"), "ordinary direct Sendable"),
            ("wrong-input", protocol.replace("init(seed: Int)", "init(seed: String)"), "ordinary direct Sendable"),
            ("extra-initializer", protocol.replace("init(seed: Int)", "init(seed: Int)\n    init(seed: Bool)"),
             "ordinary direct Sendable"),
            ("inaccessible-protocol", protocol.replace("public protocol", "protocol"), "non-generic public protocol"),
        ]:
            domain.write_text(source, encoding="utf-8")
            run(compiler + ["-typecheck", "-module-cache-path", case / "module-cache", domain],
                evidence, "compile-control-" + name)
            run([options.tool, "generate", *configured], evidence, "reject-" + name, expected=1,
                diagnostic=rf"error: BPM001: [^\n]*{diagnostic}")
            assert snapshot(output) == before

        hidden = case / "HiddenConstructor.swift"
        hidden.write_text("""@Swift.MainActor
open class HiddenConstructor {
    private init(seed: Swift.String) {}
    open func label(_ value: Swift.String) -> Swift.String { value }
}
""", encoding="utf-8")
        run(compiler + ["-typecheck", "-module-cache-path", case / "module-cache", hidden],
            evidence, "compile-control-inaccessible-super")
        status = standalone.stat()
        original_witness = (standalone.read_bytes(), status.st_ino, status.st_mtime_ns)
        run([options.tool, "subclass", "--input", hidden, "--module", "ConstructorDomain",
             "--class", "HiddenConstructor", "--override", "label(_:)", "--output", standalone],
            evidence, "reject-inaccessible-super", expected=1,
            diagnostic=r"error: BPM001: [^\n]*accessible public designated initializer")
        status = standalone.stat()
        assert (standalone.read_bytes(), status.st_ino, status.st_mtime_ns) == original_witness


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
