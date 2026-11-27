#!/usr/bin/env python3
"""Exercise both generated SDK seams against one externally compiled Swift library."""

import argparse
import json
from pathlib import Path
import platform
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MODULE = "FrozenSDK"


def run(command, evidence, label, *, expected=0, diagnostic=None):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=60)
    (evidence / f"{label}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode != expected or diagnostic and not re.search(diagnostic, result.stderr):
        raise RuntimeError(f"{label}: expected exit {expected}, got {result.returncode}\n" + result.stdout + result.stderr)
    print(f"PASS: SDK integration {label}", flush=True)
    return result.stdout


def fingerprint(file):
    status = file.stat()
    return (file.read_bytes(), status.st_mtime_ns, status.st_ino)


def write_json(file, value):
    file.write_text(json.dumps(value) + "\n", encoding="utf-8")


def verify(options):
    evidence = options.evidence_dir
    evidence.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    target = f"{architecture}-apple-macosx13.0"
    compiler = [options.swiftc, "-sdk", options.sdk, "-target", target, "-swift-version", "6"]
    fixture = ROOT / "Fixtures/SDKIntegration"
    base = ROOT / "Fixtures/ProtocolConsumer/Sources/BootstrapDomain/BootstrapRenderer.swift"

    with tempfile.TemporaryDirectory(prefix="Independent SDK ", dir=evidence) as directory:
        case = Path(directory)
        producer = case / "producer"
        producer.mkdir()
        public = case / "public"
        module = public / f"{MODULE}.swiftmodule"
        module.mkdir(parents=True)
        producer_interface = producer / f"{architecture}-apple-macos.swiftinterface"
        interface = module / producer_interface.name
        dylib = public / f"lib{MODULE}.dylib"
        native_context = json.loads(run(
            compiler + ["-print-target-info"], evidence, "read-compiler-context",
        ))
        context = case / "importer.json"
        correct = {
            "schemaVersion": 1, "compilerIdentity": native_context["compilerVersion"], "targetTriple": target,
            "swiftLanguageMode": "6", "defaultActorIsolation": "nonisolated",
            "upcomingFeatures": [], "experimentalFeatures": [], "objcInterop": True,
            "sdk": {"name": "macosx", "version": options.sdk_version},
        }
        write_json(context, correct)

        run(compiler + [
            "-parse-as-library", "-module-name", MODULE, "-enable-library-evolution",
            "-module-cache-path", producer / "cache", "-emit-module",
            "-emit-module-path", producer / f"{MODULE}.swiftmodule",
            "-emit-module-interface-path", producer_interface, "-emit-library",
            "-Xlinker", "-install_name", "-Xlinker", f"@rpath/lib{MODULE}.dylib",
            base, fixture / "FrozenQuoteSDK.swift", "-o", dylib,
        ], evidence, "compile-external-sdk")
        interface.write_bytes(producer_interface.read_bytes())
        assert set(public.iterdir()) == {module, dylib}
        assert set(module.iterdir()) == {interface}
        assert (producer / f"{MODULE}.swiftmodule").is_file()
        declared = interface.read_text(encoding="utf-8")
        assert "hiddenFee" not in declared
        quote_line = next(line for line, text in enumerate(declared.splitlines(), 1) if " func quote(" in text)

        facade = case / "FrozenQuoteSDKFacade.swift"

        def selected(class_name, method):
            return [
                options.tool, "facade", "--interface", MODULE, interface, "--importer-context", context,
                "--class", class_name, "--method", method, "--output", facade,
            ]

        success = selected("FrozenQuoteSDK", "quote(value:)")
        run(success, evidence, "generate-final-facade")
        body = facade.read_text(encoding="utf-8")
        assert "public protocol FrozenQuoteSDKFacade: Swift.Sendable" in body
        assert "public struct FrozenQuoteSDKFacadeLive: FrozenQuoteSDKFacade" in body
        assert "public final class FrozenQuoteSDKFacadeMock: FrozenQuoteSDKFacade" in body
        assert f'line: {quote_line},' in body
        before = fingerprint(facade)
        run(success, evidence, "repeat-final-facade")
        assert fingerprint(facade) == before
        for name, class_name, member, message in [
            ("hidden-member", "FrozenQuoteSDK", "hiddenFee(value:)", r"public SDK interface does not expose.*hiddenFee"),
            ("static-member", "FrozenQuoteSDK", "version(value:)", r"needs a public instance method"),
            ("non-final-class", "BootstrapRenderer", "render(_:)", r"requires a public non-generic final class"),
        ]:
            run(selected(class_name, member), evidence, "reject-" + name,
                expected=1, diagnostic=r"error: BPM001: [^\n]*" + message)
            assert fingerprint(facade) == before
        write_json(context, correct | {"compilerIdentity": "incompatible Swift compiler"})
        run(success, evidence, "reject-importer-context", expected=4,
            diagnostic=r"error: BPM005: [^\n]*compiler identity")
        assert fingerprint(facade) == before
        write_json(context, correct)

        subclass = case / "BootstrapRendererMock.swift"
        run([
            options.tool, "subclass", "--input", base, "--module", MODULE, "--class", "BootstrapRenderer",
            "--override", "render(_:)", "--output", subclass,
        ], evidence, "generate-open-subclass")
        cache = case / "consumer-cache"
        consumer = case / "IndependentSDKConsumer"
        run(compiler + [
            "-parse-as-library", "-module-cache-path", cache, "-I", public,
            "-I", options.runtime_modules, "-L", public, f"-l{MODULE}", options.runtime_library,
            "-Xlinker", "-rpath", "-Xlinker", public,
            facade, subclass, fixture / "IndependentConsumer.swift", "-o", consumer,
        ], evidence, "compile-source-less-consumer")
        assert list(cache.rglob(f"{MODULE}-*.swiftmodule"))
        observed = run([consumer], evidence, "run-source-less-consumer")
        if "PASS: A3.4 SDK integration composes the open subclass and injected facade through one binary SDK" not in observed:
            raise RuntimeError("The independent SDK consumer omitted the scenario result")

        illegal = case / "IllegalSDKSubclass.swift"
        illegal.write_text("import FrozenSDK\nfinal class Invalid: FrozenQuoteSDK {}\n", encoding="utf-8")
        run(compiler + ["-typecheck", "-I", public, "-module-cache-path", cache, illegal], evidence,
            "reject-final-subclass", expected=1, diagnostic=r"inheritance from a final class 'FrozenQuoteSDK'")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("tool", "swiftc", "sdk", "runtime-modules", "runtime-library", "evidence-dir"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--sdk-version", required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
