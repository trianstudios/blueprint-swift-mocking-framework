#!/usr/bin/env python3
"""Compile and execute a generated subclass against a separately built superclass."""
import argparse
import platform
import re
import subprocess
import tempfile
from pathlib import Path


def run(command, log):
    result = subprocess.run([str(arg) for arg in command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=90)
    log.write_text(result.stdout)
    return result


def require_success(result, label):
    if result.returncode != 0:
        raise RuntimeError(f"{label} exited {result.returncode}:\n{result.stdout}")


def verify(args):
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    runtime = args.runtime_build.resolve()
    runtime_object = runtime / "BlueprintMocking.o"
    if not runtime_object.is_file():
        raise RuntimeError("This native fixture requires the prepared BlueprintMocking.o")
    consumer = args.consumer.resolve()
    suite = args.source.read_text()

    with tempfile.TemporaryDirectory(prefix="blueprint-subclass-") as temporary:
        root = Path(temporary)
        source = root / "BootstrapRenderer.swift"
        source.write_text(suite)
        output = root / "BootstrapRendererMock.swift"
        generation = [args.tool.resolve(), "subclass", "--input", source, "--module", "BootstrapDomain",
                      "--class", "BootstrapRenderer", "--override", "render(_:)", "--output", output]
        require_success(run(generation, evidence / "subclass-generation.log"), "subclass generation")
        original = output.read_bytes()
        require_success(run(generation, evidence / "subclass-generation-repeat.log"), "repeat subclass generation")
        if output.read_bytes() != original:
            raise RuntimeError("Repeated subclass generation changed the output")
        (evidence / output.name).write_bytes(original)

        compiler = [args.swiftc.absolute(), "-swift-version", "6", "-sdk", args.sdk.resolve(), "-target",
                    f"{platform.machine()}-apple-macosx13.0", "-parse-as-library"]
        domain = root / "BootstrapDomain.o"
        require_success(run([*compiler, "-enable-library-evolution", "-emit-module", "-emit-object",
                             "-module-name", "BootstrapDomain", "-emit-module-path",
                             root / "BootstrapDomain.swiftmodule", source, "-o", domain],
                            evidence / "subclass-domain.log"), "independent superclass module")
        executable = root / "SubclassConsumer"
        require_success(run([*compiler, "-I", root, "-I", runtime, output, consumer, domain,
                             runtime_object, "-o", executable], evidence / "subclass-consumer.log"),
                        "independent subclass consumer")
        require_success(run([executable], evidence / "subclass-consumer-run.log"), "subclass consumer execution")

        modified = output.stat().st_mtime_ns
        negatives = [
            ("final-base", suite.replace("open class", "public final class").replace("open func", "public func"),
             2, "cannot subclass a final class"),
            ("closed-base", suite.replace("open class", "public class").replace("open func", "public func"),
             2, "cross-module subclass generation requires an open class"),
            ("inaccessible-init", suite.replace("public init", "private init"),
             5, "requires an accessible public designated initializer"),
            ("required-init", suite.replace("public init", "public required init"),
             5, "required initializer is unsupported"),
            ("explicit-deinit", suite.replace("    open func render", "    deinit {}\n\n    open func render"),
             9, "explicit deinitializer is unsupported"),
            ("closed-override", suite.replace("open func", "public func"),
             9, "selected override must be open"),
        ]
        for label, content, line, diagnostic in negatives:
            source.write_text(content)
            failed = run(generation, evidence / f"subclass-reject-{label}.log")
            location = rf"(?m)^{re.escape(str(source))}:{line}:\d+: error: BPM001: {re.escape(diagnostic)}"
            if failed.returncode != 1 or not re.search(location, failed.stdout):
                raise RuntimeError(f"{label} did not identify the declaration:\n{failed.stdout}")
            if output.read_bytes() != original or output.stat().st_mtime_ns != modified:
                raise RuntimeError(f"{label} changed an existing generated file")

    print("PASS: cross-module MainActor subclass bootstrap, ready dispatch and source-located rejection")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--swiftc", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--runtime-build", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    fixtures = Path(__file__).resolve().parents[1] / "Fixtures/ProtocolConsumer/Sources"
    parser.add_argument("--source", type=Path, default=fixtures / "BootstrapDomain/BootstrapRenderer.swift")
    parser.add_argument("--consumer", type=Path, default=fixtures / "SubclassBootstrapProbe/SubclassConsumer.swift")
    verify(parser.parse_args())
