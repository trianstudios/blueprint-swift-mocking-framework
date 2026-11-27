#!/usr/bin/env python3
"""Verify configured output preservation when escaping callback generation rejects a requirement."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from verify_inspection import OUTPUT_NAMES, require_unchanged, sha256, snapshot


MODULE = "ConsumerDomain"
PROTOCOL = "EscapingCallbackDirectory"
CALLBACK = "@escaping @Sendable (Int) -> String"
ASYNC_CALLBACK = CALLBACK.replace("(Int) ->", "(Int) async ->")
ASYNC_TYPED_CALLBACK = ASYNC_CALLBACK.replace("async ->", "async throws(AsyncCallbackFixtureError) ->")
TYPED_CALLBACK = CALLBACK.replace("(Int) ->", "(Int) throws(CallbackFixtureError) ->")
CANONICAL_ACTOR_CALLBACK = CALLBACK.replace("@Sendable ", "@Swift.MainActor @Sendable ")
SUPPORTED = f"func register(id: String, using callback: {CALLBACK}) -> String"
TYPED_SUPPORTED = SUPPORTED.replace(CALLBACK, TYPED_CALLBACK)
ASYNC_SUPPORTED = SUPPORTED.replace(CALLBACK, ASYNC_CALLBACK)
ASYNC_TYPED_SUPPORTED = SUPPORTED.replace(CALLBACK, ASYNC_TYPED_CALLBACK)
ACTOR_SUPPORTED = SUPPORTED.replace("@Sendable ", "@MainActor @Sendable ")
QUALIFIED_ACTOR_SUPPORTED = SUPPORTED.replace(CALLBACK, CANONICAL_ACTOR_CALLBACK)
TYPED_ENDPOINT = "SyncThrowingEscapingCallbackEndpoint<String, Int, String, String, CallbackFixtureError>"
ASYNC_ENDPOINT = "SyncAsyncEscapingCallbackEndpoint<String, Int, String, String>"
ASYNC_TYPED_ENDPOINT = (
    "SyncAsyncThrowingEscapingCallbackEndpoint<String, Int, String, String, AsyncCallbackFixtureError>"
)
ATTRIBUTES_DIAGNOSTIC = (
    "Escaping callback capture requires exactly @escaping and @Sendable, optionally with @MainActor"
)
METHOD_DIAGNOSTIC = (
    "Escaping callback capture requires a synchronous nonthrowing Sendable method with one callback "
    "in the final position"
)
ACTOR_THROWS_DIAGNOSTIC = "Typed-throwing escaping callbacks require a nonisolated @Sendable function"
ACTOR_ASYNC_DIAGNOSTIC = "Asynchronous escaping callbacks require a nonisolated @Sendable function"
FAILURE_DIAGNOSTIC = "Escaping callback capture requires throws with a named failure type other than Never"
REJECTIONS = (
    ("bare-escaping", SUPPORTED.replace("@Sendable ", ""), ATTRIBUTES_DIAGNOSTIC),
    ("non-sendable-main-actor", ACTOR_SUPPORTED.replace("@Sendable ", ""), ATTRIBUTES_DIAGNOSTIC),
    ("other-global-actor", ACTOR_SUPPORTED.replace("@MainActor ", "@WorkerActor "), ATTRIBUTES_DIAGNOSTIC),
    ("effectful-callback", ASYNC_SUPPORTED.replace("@Sendable ", "@MainActor @Sendable "), ACTOR_ASYNC_DIAGNOSTIC),
    (
        "main-actor-async-typed-callback",
        ASYNC_TYPED_SUPPORTED.replace("@Sendable ", "@MainActor @Sendable "),
        ACTOR_ASYNC_DIAGNOSTIC,
    ),
    (
        "async-untyped-throwing-callback",
        ASYNC_TYPED_SUPPORTED.replace("throws(AsyncCallbackFixtureError)", "throws"),
        FAILURE_DIAGNOSTIC,
    ),
    (
        "async-never-throwing-callback",
        ASYNC_TYPED_SUPPORTED.replace("throws(AsyncCallbackFixtureError)", "throws(Never)"),
        FAILURE_DIAGNOSTIC,
    ),
    ("main-actor-typed-callback", TYPED_SUPPORTED.replace("@Sendable ", "@MainActor @Sendable "),
     ACTOR_THROWS_DIAGNOSTIC),
    ("untyped-throwing-callback", TYPED_SUPPORTED.replace("throws(CallbackFixtureError)", "throws"), FAILURE_DIAGNOSTIC),
    ("never-throwing-callback", TYPED_SUPPORTED.replace("throws(CallbackFixtureError)", "throws(Never)"),
     FAILURE_DIAGNOSTIC),
    (
        "non-final-callback",
        "func register(using callback: @escaping @Sendable (Int) -> String, id: String) -> String",
        METHOD_DIAGNOSTIC,
    ),
    (
        "effectful-method",
        "func register(id: String, using callback: @escaping @Sendable (Int) -> String) async -> String",
        METHOD_DIAGNOSTIC,
    ),
)
REPORT_NAME = "escaping-callback-generation-report.json"


def write_source(source, method, declarations=""):
    source.write_text(
        f"public protocol {PROTOCOL}: Sendable {{\n    {method}\n}}\n"
        "public enum CallbackFixtureError: Error, Sendable { case rejected }\n"
        "public enum AsyncCallbackFixtureError: Error, Sendable { case rejected }\n"
        f"{declarations}",
        encoding="utf-8",
    )


def invoke(tool, request, evidence, label, checks):
    result = subprocess.run(
        [str(tool), *request], capture_output=True, timeout=30, check=False
    )
    artifacts = {}
    for stream, data in (("stdout", result.stdout), ("stderr", result.stderr)):
        artifact = evidence / f"escaping-callback-{label}.{stream}"
        artifact.write_bytes(data)
        artifacts[artifact.name] = sha256(data)
    checks[label] = {"exit": result.returncode, "artifacts": artifacts}
    return result


def require_rejection(result, location, diagnostic, label):
    if result.returncode != 1 or result.stdout or not re.search(
        location + rb"[^\n]*" + re.escape(diagnostic.encode("utf-8")), result.stderr
    ):
        actual = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"{label}: expected a source-located BPM001 (exit {result.returncode}): {actual}")


def require_generated(tool, request, evidence, label, checks, staged, output, *, callback=None, endpoint=None):
    generated = invoke(tool, request, evidence, label, checks)
    if generated.returncode != 0 or generated.stderr:
        diagnostic = generated.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"{label}: supported configured generation exited {generated.returncode}: {diagnostic}")
    if {path.name for path in output.iterdir()} != set(OUTPUT_NAMES):
        raise ValueError(f"{label}: configured generation did not write the two owned Swift files")
    files = tuple((output / name).read_bytes() for name in OUTPUT_NAMES)
    shard = files[0].decode("utf-8")
    if f"class {PROTOCOL}Mock" not in shard:
        raise ValueError(f"{label}: the configured protocol mock is absent from the generated shard")
    if callback is not None:
        witness = r"(?m)^    public func register\(id \w+: String, using \w+: "
        if not re.search(witness + re.escape(callback) + r"\) -> String \{", shard):
            raise ValueError(f"{label}: the emitted witness does not preserve callback type {callback}")
    if endpoint is not None and f"private let __endpoint0: {endpoint}\n" not in shard:
        raise ValueError(f"{label}: the emitted witness does not use {endpoint}")

    before = snapshot(staged)
    verified = invoke(tool, ["verify-generated", *request[1:]], evidence, f"{label}-verified", checks)
    require_unchanged(staged, before, f"{label}-verified")
    if (verified.returncode, verified.stdout, verified.stderr) != (
        0, b"Blueprint Mocking: verified 2 generated file(s)\n", b""
    ):
        diagnostic = verified.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"{label}: configured output verification exited {verified.returncode}: {diagnostic}")
    if label == "prepare":
        print("PASS: GEN016 configured generation creates both owned outputs", flush=True)
    else:
        print(f"PASS: GEN016 {label} creates two verified owned outputs", flush=True)
    return files


def reject_configured(tool, request, evidence, label, checks, staged, location, diagnostic):
    before = snapshot(staged)
    rejected = invoke(tool, request, evidence, label, checks)
    require_unchanged(staged, before, label)
    require_rejection(rejected, location, diagnostic, label)
    print(f"PASS: GEN016 {label} rejected with both owned outputs preserved", flush=True)


def verify(tool, evidence):
    checks = {}
    with tempfile.TemporaryDirectory(prefix="Configured Escaping Callback ", dir=evidence) as temporary:
        staged = Path(temporary)
        source = staged / f"{PROTOCOL}.swift"
        write_source(source, SUPPORTED)
        configuration = staged / "blueprint-mocking.json"
        selection = {"module": MODULE, "type": PROTOCOL, "kind": "protocol"}
        configuration.write_text(
            json.dumps({"schemaVersion": 1, "selections": [selection]}) + "\n", encoding="utf-8"
        )
        output = staged / "Generated Swift"
        request = [
            "generate", "--config", str(configuration), "--output", str(output), "--input-set-id", "a016",
            "--source", MODULE, str(source),
        ]
        require_generated(tool, request, evidence, "prepare", checks, staged, output)

        write_source(source, TYPED_SUPPORTED)
        require_generated(
            tool, request, evidence, "typed-throws", checks, staged, output,
            callback=TYPED_CALLBACK, endpoint=TYPED_ENDPOINT,
        )

        write_source(source, ASYNC_SUPPORTED)
        require_generated(
            tool, request, evidence, "async-callback", checks, staged, output,
            callback=ASYNC_CALLBACK, endpoint=ASYNC_ENDPOINT,
        )

        write_source(source, ASYNC_TYPED_SUPPORTED)
        require_generated(
            tool, request, evidence, "async-typed-throws", checks, staged, output,
            callback=ASYNC_TYPED_CALLBACK, endpoint=ASYNC_TYPED_ENDPOINT,
        )

        write_source(source, ACTOR_SUPPORTED)
        bare = require_generated(
            tool, request, evidence, "main-actor", checks, staged, output, callback=CANONICAL_ACTOR_CALLBACK
        )
        write_source(source, QUALIFIED_ACTOR_SUPPORTED)
        qualified = require_generated(
            tool, request, evidence, "qualified-main-actor", checks, staged, output, callback=CANONICAL_ACTOR_CALLBACK
        )
        if bare != qualified:
            raise ValueError("Bare and Swift-qualified MainActor spellings produced different owned outputs")

        location = rb"(?m)^.*" + re.escape(source.name.encode("utf-8")) + rb":[1-9]\d*:[1-9]\d*: error: BPM001: "
        for label, method, diagnostic in REJECTIONS:
            declarations = ""
            if label == "other-global-actor":
                declarations = "@globalActor public actor WorkerActor { public static let shared = WorkerActor() }\n"
            write_source(source, method, declarations)
            reject_configured(tool, request, evidence, label, checks, staged, location, diagnostic)

        shadow = staged / "ShadowedCallbackActors.swift"
        for actor_name, method, declaration in (
            (
                "MainActor", ACTOR_SUPPORTED,
                "@globalActor public actor MainActor { public static let shared = MainActor() }\n",
            ),
            (
                "Swift", QUALIFIED_ACTOR_SUPPORTED,
                "public enum Swift {\n"
                "    @globalActor public actor MainActor { public static let shared = MainActor() }\n"
                "}\n",
            ),
        ):
            write_source(source, method)
            shadow.write_text(declaration, encoding="utf-8")
            reject_configured(
                tool, [*request, "--source", MODULE, str(shadow)], evidence, f"shadowed-{actor_name.lower()}",
                checks, staged, location, f"'{actor_name}' is shadowed by a local declaration",
            )

        standalone = staged / "EscapingCallbackDirectoryMock.swift"
        standalone.write_bytes((output / OUTPUT_NAMES[0]).read_bytes())
        for label, method, option, selector, diagnostic in (
            ("callback-projection", SUPPORTED, "--project", "register(id:using:)", "cannot retain a callback requirement"),
            ("callback-forwarding", SUPPORTED.replace("id: String", "id: String..."), "--forward-variadic",
             "register(id:using:)", "cannot forward a callback requirement"),
        ):
            write_source(source, method)
            before = snapshot(staged)
            rejected = invoke(tool, [
                "--input", str(source), "--module", MODULE, "--protocol", PROTOCOL,
                "--output", str(standalone), option, selector,
            ], evidence, label, checks)
            require_unchanged(staged, before, label)
            require_rejection(rejected, location, diagnostic, label)
            print(f"PASS: GEN016 {label} rejected with standalone output preserved", flush=True)

    report = evidence / REPORT_NAME
    report.write_text(json.dumps({"checks": checks}, indent=2) + "\n", encoding="utf-8")
    print(f"EVIDENCE: {report.name} SHA-256 {sha256(report.read_bytes())}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    options = parser.parse_args()
    try:
        evidence = options.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / REPORT_NAME).unlink(missing_ok=True)
        verify(options.tool.resolve(strict=True), evidence)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Escaping callback generation verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
