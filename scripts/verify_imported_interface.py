#!/usr/bin/env python3
"""Verify a real textual Swift 6 library interface and its independent consumer."""

import argparse
import json
from pathlib import Path
import platform
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MODULE = "InterfaceDomain"
OUTPUTS = {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}


def run(command, evidence, label, *, expected=0, diagnostic=None):
    completed = subprocess.run(
        list(map(str, command)), capture_output=True, text=True, timeout=60,
    )
    (evidence / f"{label}.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode != expected or (
        diagnostic and not re.search(diagnostic, completed.stderr)
    ):
        raise RuntimeError(
            f"{label}: expected exit {expected}, got {completed.returncode}\n"
            + completed.stdout + completed.stderr
        )
    print(f"PASS: GEN003 {label}", flush=True)
    return completed.stdout


def snapshot(directory):
    result = {}
    for path in sorted(directory.iterdir()):
        stat = path.stat()
        result[path.name] = (stat.st_ino, stat.st_mode, stat.st_mtime_ns, path.read_bytes())
    return result


def verify(tool, swiftc, sdk, sdk_version, runtime_modules, runtime_library, evidence, flags):
    architecture = platform.machine()
    alternatives = {"arm64": "x86_64", "x86_64": "arm64"}
    other_architecture = alternatives[architecture]
    target = f"{architecture}-apple-macosx13.0"
    other_target = f"{other_architecture}-apple-macosx13.0"
    evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="Imported Interface ", dir=evidence) as directory:
        staged = Path(directory)
        producer = staged / "producer"
        producer.mkdir()
        inputs = staged / "import"
        modules = inputs / f"{MODULE}.swiftmodule"
        modules.mkdir(parents=True)
        output = staged / "generated"
        actual = modules / f"{architecture}-apple-macos.swiftinterface"
        wrong_arch = producer / f"{other_architecture}-apple-macos.swiftinterface"
        context = staged / "context.json"
        config = staged / "blueprint-mocking.json"
        fixture = ROOT / "Fixtures/ImportedInterface"
        source = fixture / f"{MODULE}.swift"
        consumer = fixture / "IndependentConsumer.swift"
        native = [swiftc, "-sdk", sdk, "-swift-version", "6"]
        target_info = json.loads(run(
            [swiftc, "-print-target-info", "-sdk", sdk, "-target", target], evidence, "compiler-context",
        ))
        initial = {
            "schemaVersion": 1,
            "compilerIdentity": target_info["compilerVersion"],
            "targetTriple": target,
            "swiftLanguageMode": "6",
            "defaultActorIsolation": "nonisolated",
            "upcomingFeatures": [],
            "experimentalFeatures": [],
            "objcInterop": True,
            "sdk": {"name": "macosx", "version": sdk_version},
        }

        def write_json(path, payload):
            path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

        write_json(context, initial)
        write_json(config, {"schemaVersion": 1, "selections": [
            {"module": MODULE, "type": "ImportedDirectory", "kind": "protocol"},
        ]})
        producer_flags = ["-parse-as-library", "-module-name", MODULE, "-enable-library-evolution",
                          "-module-cache-path", producer / "cache", *flags, "-emit-module", source]
        producer_interface = producer / f"{architecture}-apple-macos.swiftinterface"
        run(native + ["-target", target, *producer_flags,
                      "-emit-module-path", producer / f"{MODULE}.swiftmodule",
                      "-emit-module-interface-path", producer_interface, "-emit-library",
                      "-o", inputs / f"lib{MODULE}.dylib"], evidence, "emit-public-interface")
        actual.write_bytes(producer_interface.read_bytes())
        assert {path.name for path in modules.iterdir()} == {actual.name}

        request = ["--config", config, "--output", output, "--input-set-id", "a003"]
        arguments = ["--interface", MODULE, actual, "--importer-context", context]
        run([tool, "generate", *request, *arguments], evidence, "configured-interface-generation")
        before = snapshot(output)
        assert set(before) == OUTPUTS
        shard = (output / "BlueprintMocks.generated.swift").read_text(encoding="utf-8")
        assert "public final class ImportedDirectoryMock: InterfaceDomain.ImportedDirectory" in shard
        assert "SyncEndpoint<Swift.String, Swift.String>" in shard
        run([tool, "verify-generated", *request, *arguments], evidence, "verify-owned-outputs")
        assert snapshot(output) == before
        inspection = json.loads(run(
            [tool, "inspect", *request, *arguments, "--format", "json"], evidence, "inspect-imported-context",
        ))
        recorded = inspection["inputs"]["importedInterface"]
        assert recorded["importer"]["sdk"] == initial["sdk"]
        assert "sdk" in recorded["unavailableProducerContext"]
        assert recorded["module"] == MODULE and inspection["inputs"]["sources"] == []
        assert snapshot(output) == before

        exercise = staged / "independent-consumer"
        run(native + ["-target", target, "-parse-as-library", "-module-name", "IndependentConsumer",
                      "-I", inputs, "-L", inputs, f"-l{MODULE}", "-I", runtime_modules, runtime_library,
                      "-module-cache-path", staged / "fresh-consumer-cache",
                      "-Xlinker", "-rpath", "-Xlinker", inputs,
                      output / "BlueprintMocks.generated.swift", output / "BlueprintMockingIndex.generated.swift",
                      consumer, "-o", exercise], evidence, "compile-independent-consumer")
        assert list((staged / "fresh-consumer-cache").rglob("InterfaceDomain-*.swiftmodule"))
        run([exercise], evidence, "run-independent-binary-consumer")

        run(native + ["-target", other_target, *producer_flags,
                      "-emit-module-path", producer / f"{MODULE}-{other_architecture}.swiftmodule",
                      "-emit-module-interface-path", wrong_arch], evidence, "emit-real-wrong-target-interface")
        for label, candidate, module, diagnostic in (
            ("wrong-module", actual, "WrongModule", r"module.*WrongModule.*InterfaceDomain"),
            ("wrong-target", wrong_arch, MODULE, rf"target.*{re.escape(target)}.*{re.escape(other_target)}"),
        ):
            run([tool, "generate", *request, "--interface", module, candidate, "--importer-context", context],
                evidence, "reject-" + label, expected=4,
                diagnostic=r"error: BPM005: [^\n]*" + diagnostic)
            assert snapshot(output) == before
        for label, change, diagnostic in (
            ("compiler", {"compilerIdentity": "different Swift compiler"}, "compiler identity"),
            ("language", {"swiftLanguageMode": "5"}, "language mode"),
            ("isolation", {"defaultActorIsolation": "MainActor"}, "actor isolation"),
            ("feature", {"upcomingFeatures": ["ExistentialAny"]}, "features"),
        ):
            write_json(context, initial | change)
            run([tool, "generate", *request, *arguments], evidence, "reject-" + label, expected=4,
                diagnostic=r"error: BPM005: [^\n]*" + diagnostic)
            assert snapshot(output) == before

        write_json(context, initial)
        for option, arguments in (
            ("raw-source", ["--source", MODULE, actual]),
            ("missing-context", ["--interface", MODULE, actual]),
        ):
            run([tool, "generate", *request, *arguments], evidence, "reject-" + option,
                expected=4, diagnostic=r"error: BPM005: [^\n]*--importer-context")
            assert snapshot(output) == before

        standalone = staged / "ExistingMock.swift"
        standalone.write_text(shard, encoding="utf-8")
        previous_file = (standalone.read_bytes(), standalone.stat().st_mtime_ns)
        run([tool, "--input", actual, "--module", MODULE, "--protocol", "ImportedDirectory",
             "--output", standalone], evidence, "reject-legacy-input", expected=4,
            diagnostic=r"error: BPM005: [^\n]*--interface and --importer-context")
        assert (standalone.read_bytes(), standalone.stat().st_mtime_ns) == previous_file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + argument, type=Path, required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--dot-interface", action="store_true",
                        help="Emit real pre-module-selector style interfaces on an emitting toolchain that supports it.")
    options = parser.parse_args()
    flags = ["-Xfrontend", "-disable-module-selectors-in-module-interface"] if options.dot_interface else []
    verify(options.tool.resolve(), options.swiftc, options.sdk, options.sdk_version,
           options.runtime_modules.resolve(), options.runtime_library.resolve(), options.evidence_dir, flags)


if __name__ == "__main__":
    main()
