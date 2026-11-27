#!/usr/bin/env python3
"""One entry point for the supported local prototype profile; no network dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile

from check_release import read_registry
from fatal_child import check_fatal_child

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = Path(os.environ.get("BLUEPRINT_EVIDENCE_DIRECTORY", ROOT / "Evidence")).resolve()
RESULTS = []
DEFAULT_VALUE_FAILURE_CASES = (
    ("default-unregistered-terminates", "--unregistered-default-value",
     r"No registered default factory for ConsumerDomain\.DefaultCatalogProduct for catalog\.lookup$"),
    ("default-cycle-terminates", "--cyclic-default-value",
     r"Default-value cycle: ConsumerDomain\.DefaultCatalogProduct -> ConsumerDomain\.DefaultCatalogRegion"
     r" -> ConsumerDomain\.DefaultCatalogProduct for catalog\.lookup$"),
)

def run(name, command, *, fails=False, patterns=(), env=None, timeout=120):
    completed = subprocess.run(
        [str(x) for x in command], cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = completed.stdout
    valid = (completed.returncode != 0) if fails else (completed.returncode == 0)
    valid = valid and all(re.search(pattern, output) for pattern in patterns)
    return record_result(name, output, completed.returncode, valid, expected_failure=fails)


def record_result(name, output, returncode, valid, *, expected_failure):
    log = EVIDENCE / (name + ".log")
    log.write_text(output, encoding="utf-8")
    RESULTS.append({"check": name, "passed": bool(valid), "exit": returncode,
                    "expected_failure": expected_failure, "log": log.name,
                    "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
    print(("PASS " if valid else "FAIL ") + name, flush=True)
    if not valid:
        print(output[-10000:], flush=True)
        raise RuntimeError(name)
    return output

def generate(tool, source, output, selected="UserRepository", projections=(), *,
             module="ConsumerDomain", forwarding=(), specializations=(), spy=False, sources=(),
             associated_bindings=(), method_specializations=(), generic_providers=(), rethrows_providers=(), scoped_rules=(),
             lazy_autoclosures=(), materialized_autoclosures=()):
    arguments = [tool, "--input", source, "--module", module,
                 "--protocol", selected, "--output", output]
    for projection in projections:
        arguments.extend(["--project", projection])
    for method in forwarding:
        arguments.extend(["--forward-variadic", method])
    for specialization in specializations:
        arguments.extend(["--specialize-subscript", specialization])
    for specialization in method_specializations:
        arguments.extend(["--specialize-method", specialization])
    for provider in generic_providers:
        arguments.extend(["--generic-provider", provider])
    for provider in rethrows_providers:
        arguments.extend(["--rethrows-provider", provider])
    for selector in scoped_rules:
        arguments.extend(["--scoped-rule", selector])
    for selector in lazy_autoclosures:
        arguments.extend(["--lazy-autoclosure", selector])
    for selector in materialized_autoclosures:
        arguments.extend(["--materialized-autoclosure", selector])
    if spy:
        arguments.append("--spy")
    for source_module, path in sources:
        arguments.extend(["--source", source_module, path])
    for binding in associated_bindings:
        arguments.extend(["--bind-associated-type", binding])
    return arguments

def verify_fluent_self_generation(tool, source, generated, fixed, scratch):
    run("fluent-self-generation", generate(tool, source, generated, "FluentDirectory"))
    with tempfile.TemporaryDirectory(prefix="FluentSelf-", dir=scratch) as directory:
        configured = Path(directory)
        authored = configured / "FluentDirectory.swift"
        authored.write_bytes(source.read_bytes())
        configuration = configured / "blueprint-mocking.json"
        configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "ConsumerDomain", "type": "FluentDirectory", "kind": "protocol"},
        ]}), encoding="utf-8")
        output = configured / "Generated Swift"
        request = ["--config", configuration, "--output", output, "--input-set-id", "a009",
                   "--source", "ConsumerDomain", authored]
        run("fluent-self-configured-generation", [tool, "generate", *request])
        def snapshot():
            files = {}
            for file in sorted(output.iterdir()):
                stat = file.stat()
                files[file.name] = (stat.st_ino, stat.st_mode, stat.st_mtime_ns, file.read_bytes())
            return files

        before = snapshot()
        assert set(before) == {"BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift"}
        run("fluent-self-configured-verification", [tool, "verify-generated", *request])
        if snapshot() != before:
            raise ValueError("Verifying fluent Self generation changed owned outputs")
        async_variant = source.read_text(encoding="utf-8").replace("-> Self", "async -> Self", 1)
        for label, text, diagnostic in (
            ("fixed", fixed.read_text(encoding="utf-8").replace("FixedSelfDirectory", "FluentDirectory"),
             r"Self is fixed to final class 'ConsumerDomain\.FixedDirectory'"),
            ("effect", async_variant, r"A fluent Self result requires a direct synchronous nonthrowing Sendable method"),
        ):
            authored.write_text(text, encoding="utf-8")
            run("fluent-self-configured-reject-" + label, [tool, "generate", *request],
                fails=True, patterns=[r"FluentDirectory\.swift:\d+:\d+: error: BPM001: " + diagnostic])
            if snapshot() != before:
                raise ValueError("Rejected fluent Self generation changed existing owned outputs")


def verify_lazy_autoclosure_generation(tool, source, generated, scratch):
    selection = ("choose(id:fallback:)",)
    run("lazy-autoclosure-generation", generate(
        tool, source, generated, "LazyChoiceDirectory", lazy_autoclosures=selection))
    rejected = scratch / "RejectedLazyAutoclosure.swift"
    rejected.write_bytes(generated.read_bytes())
    baseline = (rejected.read_bytes(), rejected.stat().st_mtime_ns)
    original = source.read_text(encoding="utf-8")
    cases = [
        ("without-opt-in", source, (), r"explicit --lazy-autoclosure method selector"),
        ("duplicate", source, selection * 2, r"Duplicate lazy autoclosure selector"),
    ]
    for label, thunk in (
        ("async", "() async -> Int"),
        ("throwing", "() throws -> Int"),
        ("escaping", "@escaping () -> Int"),
        ("sendable", "@Sendable () -> Int"),
    ):
        variant = scratch / f"LazyAutoclosure-{label}.swift"
        variant.write_text(original.replace("() -> Int", thunk), encoding="utf-8")
        cases.append((label, variant, selection, r"nonescaping synchronous nonthrowing @autoclosure"))
    for label, authored, selectors, diagnostic in cases:
        run("lazy-autoclosure-reject-" + label, generate(
            tool, authored, rejected, "LazyChoiceDirectory", lazy_autoclosures=selectors),
            fails=True, patterns=[re.escape(authored.name) + r":\d+:\d+: error: BPM001:[^\n]*" + diagnostic])
        if (rejected.read_bytes(), rejected.stat().st_mtime_ns) != baseline:
            raise ValueError("Rejected lazy autoclosure generation changed valid prior output")


def verify_materialized_autoclosure_generation(tool, source, generated, scratch):
    selection = ("choose(id:fallback:)", "record(fallback:)")
    run("materialized-autoclosure-generation", generate(
        tool, source, generated, "MaterializedChoiceDirectory", materialized_autoclosures=selection))
    rejected = scratch / "RejectedMaterializedAutoclosure.swift"
    rejected.write_bytes(generated.read_bytes())
    baseline = (rejected.read_bytes(), rejected.stat().st_mtime_ns)
    unsupported = scratch / "MaterializedAutoclosure-unsupported.swift"
    unsupported.write_text(source.read_text(encoding="utf-8").replace("() -> Int", "() -> [Int]", 1),
                           encoding="utf-8")
    cases = (
        ("mixed", source, selection, (selection[0],), r"cannot request both lazy and materialized modes"),
        ("duplicate", source, (*selection, selection[0]), (), r"Duplicate materialized autoclosure selector"),
        ("unsupported-value", unsupported, selection, (), r"require a Bool, Int or String value"),
    )
    for label, authored, materialized, lazy, diagnostic in cases:
        run("materialized-autoclosure-reject-" + label, generate(
            tool, authored, rejected, "MaterializedChoiceDirectory",
            materialized_autoclosures=materialized, lazy_autoclosures=lazy), fails=True,
            patterns=[re.escape(authored.name) + r":\d+:\d+: error: BPM001:[^\n]*" + diagnostic])
        if (rejected.read_bytes(), rejected.stat().st_mtime_ns) != baseline:
            raise ValueError("Rejected materialized autoclosure generation changed valid prior output")


def verify_isolated_actor_generation(tool, source, generated, scratch, compiler, env=None):
    run("isolated-actor-generation", generate(tool, source, generated, "IsolatedActorDirectory"))
    with tempfile.TemporaryDirectory(prefix="IsolatedActor-", dir=scratch) as directory:
        configured = Path(directory)
        authored = configured / source.name
        authored.write_bytes(source.read_bytes())
        configuration = configured / "blueprint-mocking.json"
        configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "ConsumerDomain", "type": "IsolatedActorDirectory", "kind": "protocol"},
        ]}), encoding="utf-8")
        output = configured / "Generated Swift"
        request = ["--config", configuration, "--output", output, "--input-set-id", "a036",
                   "--source", "ConsumerDomain", authored]
        run("isolated-actor-configured-generation", [tool, "generate", *request])
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"

        def snapshot():
            return [(file.read_bytes(), file.stat().st_mtime_ns) for file in (shard, index)]

        baseline = snapshot()
        expected_shard = (b"// Generated by Blueprint Mocking. Do not edit.\n"
                          + generated.read_bytes().rstrip() + b"\n\nenum BlueprintMockingShard_")
        if not baseline[0][0].startswith(expected_shard):
            raise ValueError("Standalone and configured isolated actor witnesses disagree")
        run("isolated-actor-configured-verification", [tool, "verify-generated", *request])
        if snapshot() != baseline:
            raise ValueError("Verifying isolated actor generation changed the outputs")

        entity = "public actor Worker {}\n"
        variants = (
            ("async", "", "_ worker: isolated Worker", " async", "direct synchronous nonthrowing Sendable method"),
            ("existential", "", "_ worker: isolated any Actor", "", "direct synchronous nonthrowing Sendable method"),
            ("additional-input", "", "_ worker: isolated Worker, by amount: Int", "",
             "direct synchronous nonthrowing Sendable method"),
            ("alias", "public typealias WorkerAlias = Worker\n", "_ worker: isolated WorkerAlias", "",
             "one unconditional public nongeneric actor"),
        )
        for label, declarations, parameters, effect, diagnostic in variants:
            authored.write_text(
                entity + declarations + "public protocol IsolatedActorDirectory: Sendable {\n"
                f"    func sample({parameters}){effect} -> Int\n"
                "}\n", encoding="utf-8")
            run("isolated-actor-native-shape-" + label,
                [*compiler, "-typecheck", "-module-name", "ConsumerDomain", authored], env=env)
            run("isolated-actor-configured-reject-" + label, [tool, "generate", *request], fails=True,
                patterns=[r"IsolatedActorDirectory\.swift:\d+:\d+: error: BPM001:[^\n]*" + diagnostic])
            if snapshot() != baseline:
                raise ValueError("Rejected isolated actor generation changed valid outputs")


def verify_consuming_input_generation(tool, source, generated, scratch, compiler, env=None):
    run("consuming-input-generation", generate(tool, source, generated, "ConsumingTicketReceiver"))
    with tempfile.TemporaryDirectory(prefix="ConsumingInput-", dir=scratch) as directory:
        configured = Path(directory)
        authored = configured / source.name
        authored.write_bytes(source.read_bytes())
        configuration = configured / "blueprint-mocking.json"
        configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "ConsumerDomain", "type": "ConsumingTicketReceiver", "kind": "protocol"},
        ]}), encoding="utf-8")
        output = configured / "Generated Swift"
        request = ["--config", configuration, "--output", output, "--input-set-id", "a032",
                   "--source", "ConsumerDomain", authored]
        run("consuming-input-configured-generation", [tool, "generate", *request])
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"

        def snapshot():
            return [(file.read_bytes(), file.stat().st_mtime_ns) for file in (shard, index)]

        baseline = snapshot()
        expected_shard = (b"// Generated by Blueprint Mocking. Do not edit.\n"
                          + generated.read_bytes().rstrip() + b"\n\nenum BlueprintMockingShard_")
        if not baseline[0][0].startswith(expected_shard):
            raise ValueError("Standalone and configured consuming input witnesses disagree")
        run("consuming-input-configured-verification", [tool, "verify-generated", *request])
        if snapshot() != baseline:
            raise ValueError("Verifying consuming input generation changed the outputs")

        for label, conformance, effect, diagnostic in (
            ("async", ": ~Copyable", " async", r"direct synchronous nonthrowing Sendable method"),
            ("copyable", "", "", r"one unconditional public nongeneric struct"),
        ):
            authored.write_text(
                f"public struct Ticket{conformance} {{}}\n"
                "public protocol ConsumingTicketReceiver: Sendable {\n"
                f"    func receive(_ ticket: consuming Ticket){effect} -> Int\n"
                "}\n", encoding="utf-8")
            run("consuming-input-native-shape-" + label,
                [*compiler, "-typecheck", "-module-name", "ConsumerDomain", authored], env=env)
            run("consuming-input-configured-reject-" + label, [tool, "generate", *request], fails=True,
                patterns=[r"ConsumingTicketReceiver\.swift:\d+:\d+: error: BPM001:[^\n]*" + diagnostic])
            if snapshot() != baseline:
                raise ValueError("Rejected consuming input generation changed valid outputs")


def verify_sending_generation(tool, source, generated, scratch):
    run("sending-generation", generate(tool, source, generated, "SendingPacketDirectory"))
    with tempfile.TemporaryDirectory(prefix="SendingTransfer-", dir=scratch) as directory:
        configured = Path(directory)
        authored = configured / source.name
        authored.write_bytes(source.read_bytes())
        configuration = configured / "blueprint-mocking.json"
        configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "ConsumerDomain", "type": "SendingPacketDirectory", "kind": "protocol"},
        ]}), encoding="utf-8")
        output = configured / "Generated Swift"
        request = ["--config", configuration, "--output", output, "--input-set-id", "a034",
                   "--source", "ConsumerDomain", authored]
        run("sending-configured-generation", [tool, "generate", *request])
        paths = [output / name for name in ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")]

        def snapshot():
            return [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]

        previous = snapshot()
        expected_shard = (b"// Generated by Blueprint Mocking. Do not edit.\n"
                          + generated.read_bytes().rstrip() + b"\n\nenum BlueprintMockingShard_")
        if not previous[0][0].startswith(expected_shard):
            raise ValueError("Standalone and configured sending witnesses disagree")
        run("sending-configured-verification", [tool, "verify-generated", *request])
        if snapshot() != previous:
            raise ValueError("Verifying sending witnesses changed existing generated outputs")

        original = source.read_text(encoding="utf-8")
        for label, before, after, diagnostic in (
            ("input-only", "-> sending SendingPacket", "-> SendingPacket",
             r"requires a direct async nonthrowing Sendable method"),
            ("result-only", "input: sending SendingPacket", "input: SendingPacket",
             r"requires a direct async nonthrowing Sendable method"),
            ("throwing", "async ->", "async throws ->", r"requires a direct async nonthrowing Sendable method"),
            ("nonfinal", "public final class", "public class", r"requires one unconditional public final nongeneric class"),
        ):
            authored.write_text(original.replace(before, after, 1), encoding="utf-8")
            run("reject-sending-" + label, [tool, "generate", *request], fails=True,
                patterns=[re.escape(source.name) + r":\d+:\d+: error: BPM001: [^\n]*" + diagnostic])
            if snapshot() != previous:
                raise ValueError("Rejected sending witness changed existing generated outputs")


def verify_owned_result_generation(tool, source, generated, scratch, compiler, env=None):
    run("owned-result-generation", generate(tool, source, generated, "FreshOwnedTicketSource"))
    with tempfile.TemporaryDirectory(prefix="OwnedResult-", dir=scratch) as directory:
        configured = Path(directory)
        authored = configured / source.name
        authored.write_bytes(source.read_bytes())
        configuration = configured / "blueprint-mocking.json"
        configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "ConsumerDomain", "type": "FreshOwnedTicketSource", "kind": "protocol"},
        ]}), encoding="utf-8")
        output = configured / "Generated Swift"
        request = ["--config", configuration, "--output", output, "--input-set-id", "a033",
                   "--source", "ConsumerDomain", authored]
        run("owned-result-configured-generation", [tool, "generate", *request])
        shard = output / "BlueprintMocks.generated.swift"
        index = output / "BlueprintMockingIndex.generated.swift"

        def snapshot():
            return [(file.read_bytes(), file.stat().st_mtime_ns) for file in (shard, index)]

        baseline = snapshot()
        expected_shard = (b"// Generated by Blueprint Mocking. Do not edit.\n"
                          + generated.read_bytes().rstrip() + b"\n\nenum BlueprintMockingShard_")
        if not baseline[0][0].startswith(expected_shard):
            raise ValueError("Standalone and configured owned-result witnesses disagree")
        run("owned-result-configured-verification", [tool, "verify-generated", *request])
        if snapshot() != baseline:
            raise ValueError("Verifying owned-result generation changed the outputs")

        authored.write_text(
            "public struct FreshTicket: ~Copyable {}\n"
            "public protocol FreshOwnedTicketSource: Sendable {\n"
            "    func issue(_ key: Int) async -> FreshTicket\n"
            "}\n", encoding="utf-8")
        run("owned-result-native-async-shape", [*compiler, "-typecheck", "-module-name", "ConsumerDomain", authored],
            env=env)
        run("owned-result-configured-reject-async", [tool, "generate", *request], fails=True,
            patterns=[r"FreshOwnedTicketSource\.swift:\d+:\d+: error: BPM001:[^\n]*direct synchronous nonthrowing"])
        if snapshot() != baseline:
            raise ValueError("Rejected owned-result generation changed valid outputs")


def verify_byte_buffer_projection_generation(tool, source, generated, scratch):
    selected = "SnapshotByteBufferReader"
    run("byte-buffer-projection-generation", generate(tool, source, generated, selected))
    with tempfile.TemporaryDirectory(prefix="ByteBufferProjection-", dir=scratch) as directory:
        configured = Path(directory)
        authored = configured / source.name
        authored.write_bytes(source.read_bytes())
        configuration = configured / "blueprint-mocking.json"
        configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "ConsumerDomain", "type": selected, "kind": "protocol"},
        ]}), encoding="utf-8")
        output = configured / "Generated Swift"
        request = ["--config", configuration, "--output", output, "--input-set-id", "a040",
                   "--source", "ConsumerDomain", authored]
        run("byte-buffer-projection-configured-generation", [tool, "generate", *request])
        paths = [output / name for name in ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")]
        previous = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        expected_shard = (b"// Generated by Blueprint Mocking. Do not edit.\n"
                          + generated.read_bytes().rstrip() + b"\n\nenum BlueprintMockingShard_")
        if not previous[0][0].startswith(expected_shard):
            raise ValueError("Standalone and configured byte-buffer snapshot witnesses disagree")
        run("byte-buffer-projection-configured-verification", [tool, "verify-generated", *request])
        if [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths] != previous:
            raise ValueError("Verifying the byte-buffer snapshot changed its outputs")

    rejected = scratch / "RejectedRawByteBuffer.swift"
    rejected.write_bytes(generated.read_bytes())
    previous = (rejected.read_bytes(), rejected.stat().st_mtime_ns)
    run("byte-buffer-projection-reject-raw", generate(tool, source, rejected, "BorrowedByteBufferReader"),
        fails=True, patterns=[r"error: BPM001:[^\n]*Use named, optional, array or dictionary parameter types"])
    if (rejected.read_bytes(), rejected.stat().st_mtime_ns) != previous:
        raise ValueError("Rejected raw buffer generation replaced the valid snapshot fixture")


def xcrun(*arguments):
    return subprocess.check_output(["xcrun", *arguments], text=True).strip()

def checkout_state():
    def git(*arguments):
        return subprocess.check_output(
            ["git", *arguments], cwd=ROOT, stderr=subprocess.DEVNULL, text=True,
            env=os.environ | {"GIT_OPTIONAL_LOCKS": "0"}, timeout=20,
        ).strip()

    try:
        if Path(git("rev-parse", "--show-toplevel")).resolve() != ROOT:
            return None
        return {
            "revision": git("rev-parse", "--verify", "HEAD"),
            "clean": not git("status", "--porcelain", "--untracked-files=normal"),
        }
    except (OSError, subprocess.SubprocessError):
        return None


def result_document():
    return (json.dumps(RESULTS, indent=2) + "\n").encode("utf-8")


def verify_release_checks():
    for suite in ("test_check_release.py", "test_verify_release_candidate.py"):
        run(suite, [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-p", suite, "-v"],
            patterns=[r"(?m)^Ran [1-9]\d* tests? in ", r"(?m)^OK$"])


def verify_local_release_checks():
    report_path = EVIDENCE / "release-checks.json"
    report_path.unlink(missing_ok=True)
    source_before = checkout_state()
    if not source_before or not source_before["clean"]:
        raise ValueError("Release checks require a clean Git checkout")

    verify_release_checks()

    source_after = checkout_state()
    if source_before != source_after:
        raise ValueError("The Git checkout changed during release checks")
    report = {
        "status": "local release checks",
        "sourceRevision": source_before["revision"],
        "checkoutBefore": source_before,
        "checkoutAfter": source_after,
        "python": platform.python_version(),
        "pythonPath": sys.executable,
        "host": platform.platform(),
        "hostKernelBuild": platform.version(),
        "results": RESULTS,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def verify_conditional_generation(tool, temp):
    source = ROOT / "Fixtures/ConditionalConsumer/Sources/ConditionalDomain/ConditionalDirectory.swift"
    flag = "BLUEPRINT_DOMAIN_INT"
    module = "ConditionalDomain"
    selection = {"schemaVersion": 1, "selections": [
        {"module": module, "type": "ConditionalDirectory", "kind": "protocol"},
    ]}
    configuration = temp / "conditional-blueprint-mocking.json"
    configuration.write_text(json.dumps(selection))
    output = temp / "conditional-batch"
    arguments = [
        "--config", configuration, "--output", output, "--input-set-id", "7", "--source", module, source,
    ]
    true_context = ["--source-condition", module, flag, "true"]
    false_context = ["--source-condition", module, flag, "false"]
    report = json.loads(run("conditional-config-inspection", [
        tool, "inspect", *arguments, *true_context, "--format", "json",
    ]))
    assert report["inputs"]["sourceConditions"] == {module: {flag: True}}

    files = [output / "BlueprintMocks.generated.swift", output / "BlueprintMockingIndex.generated.swift"]
    run("conditional-config-int", [tool, "generate", *arguments, *true_context])
    previous = [file.read_bytes() for file in files]
    assert b"public func value() -> Int {" in previous[0] and b"#if" not in previous[0]
    assert b'line: 3, column: 1' in previous[0]
    run("conditional-config-string", [tool, "generate", *arguments, *false_context])
    current = [(file.read_bytes(), file.stat().st_mtime_ns) for file in files]
    assert b"public func value() -> String {" in current[0][0] and b"#if" not in current[0][0]
    assert b'line: 5, column: 1' in current[0][0]
    assert all(old != new for old, (new, _) in zip(previous, current, strict=True))

    run("reject-conditional-config-missing", [
        tool, "generate", *arguments, "--source-condition", "ConditionalProbe", flag, "true",
    ], fails=True, patterns=[rf"BPM001: Missing compilation condition '{flag}' for source module '{module}'"])
    run("reject-conditional-config-duplicate", [
        tool, "generate", *arguments, *true_context, *false_context,
    ], fails=True, patterns=[rf"BPM002: Duplicate source condition '{flag}' for module '{module}'"])
    assert [(file.read_bytes(), file.stat().st_mtime_ns) for file in files] == current

    nested_source = temp / "ConditionalDirectory.swift"
    original = source.read_text()
    nested = original.replace("    func value() -> String", (
        "#if BLUEPRINT_NESTED\n    func value() -> Bool\n#else\n    func value() -> String\n#endif"
    ))
    assert nested != original
    nested_source.write_text(nested)
    nested_arguments = [*arguments[:-1], nested_source]
    run("conditional-inactive-nested", [tool, "generate", *nested_arguments, *true_context])
    assert b"public func value() -> Int {" in files[0].read_bytes()
    run("reject-conditional-active-nested-missing", [tool, "generate", *nested_arguments, *false_context],
        fails=True, patterns=[rf"BPM001: Missing compilation condition 'BLUEPRINT_NESTED' for source module '{module}'"])

    compound = original.replace(f"#if {flag}", f"#if {flag} && BLUEPRINT_NESTED")
    nested_source.write_text(compound)
    last_valid = [file.read_bytes() for file in files]
    run("reject-conditional-unsupported-expression", [tool, "generate", *nested_arguments, *true_context],
        fails=True, patterns=[r"BPM001: Unsupported compilation condition. Use one bare custom identifier"])
    assert [file.read_bytes() for file in files] == last_valid


def main():
    source_before = checkout_state()
    offline_runtime_mirror = os.environ.get("BLUEPRINT_VERIFY_OFFLINE_RUNTIME_MIRROR")
    if offline_runtime_mirror and (not source_before or not source_before["clean"]):
        raise ValueError("Offline runtime qualification requires a clean Git checkout at the mirror revision")
    tooling_archive_mirror = os.environ.get("BLUEPRINT_VERIFY_TOOLING_ARCHIVE_MIRROR")
    if tooling_archive_mirror and (not source_before or not source_before["clean"]):
        raise ValueError("Tooling archive qualification requires a clean Git checkout")
    swift = Path(xcrun("--find", "swift"))
    swiftc = Path(xcrun("--find", "swiftc"))
    if any(not executable.is_absolute() or not os.access(executable, os.X_OK)
           for executable in (swift, swiftc)):
        raise RuntimeError("xcrun must select executable Swift and swiftc files")
    if swift.parent.resolve() != swiftc.parent.resolve():
        raise RuntimeError("xcrun selected Swift and swiftc from different toolchains")
    sdk = xcrun("--sdk", "macosx", "--show-sdk-path")
    sdk_version = xcrun("--sdk", "macosx", "--show-sdk-version")
    if not Path(sdk).is_dir():
        raise RuntimeError("xcrun must select an installed macOS SDK")
    deployment_target = (ROOT / "scripts/macos-deployment-target").read_text().strip()
    swift_environment = os.environ | {"SWIFT_EXEC": str(swiftc), "SDKROOT": sdk}
    swift_environment.pop("BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE", None)
    swift_environment.pop("BLUEPRINT_EXPECT_PARAMETERIZED_REPORTER_FAILURE", None)
    swift_environment.pop("BLUEPRINT_CLOSED_OWNER_BRIDGE", None)
    swift_version = subprocess.check_output(
        [str(swift), "--version"], text=True, stderr=subprocess.STDOUT, env=swift_environment
    ).strip()
    compiler_version = subprocess.check_output(
        [str(swiftc), "--version"], text=True, stderr=subprocess.STDOUT, env=swift_environment
    ).strip()

    def run_swift(name, arguments, *, extra_environment=None, **expectations):
        return run(name, [swift, *arguments],
                   env=swift_environment | (extra_environment or {}), **expectations)

    matrix = ROOT / "Docs/Acceptance-Status.csv"
    rows, registry_errors = read_registry(matrix)
    if registry_errors:
        raise ValueError("Invalid acceptance matrix:\n" + "\n".join(registry_errors))
    verify_release_checks()
    source = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDomain/UserRepository.swift"
    generated = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/UserRepositoryMock.swift"
    generation_environment = swift_environment | {
        "BLUEPRINT_VERIFY_SWIFTC": str(swiftc),
        "BLUEPRINT_VERIFY_SDK_PATH": sdk,
        "BLUEPRINT_TEST_PUBLICATION_TOOL": "0",
    }
    run("generation", [
        "bash", "scripts/generate.sh", "--input", source, "--module", "ConsumerDomain",
        "--protocol", "UserRepository", "--output", generated], env=generation_environment)
    tool = ROOT / ".build/prototype-tooling/generate"
    run("runtime-schema-generated-compatibility", [
        sys.executable, "scripts/verify_runtime_schema.py", "--tool", tool,
        "--swiftc", swiftc, "--sdk", sdk, "--evidence-dir", EVIDENCE,
    ], env=swift_environment, timeout=360, patterns=[
        r"PASS: GEN007 emitted witnesses reject an incompatible runtime despite a consumer-local schema lookalike",
        r"PASS: GEN007 configured manifest compiles and detects runtime contract version drift",
        r"EVIDENCE: runtime-schema-report\.json SHA-256 [0-9a-f]{64}",
    ])
    publication_fixture = ROOT / "Fixtures/OfflineGenerationConsumer"
    run("generation-recovery-fault-tool", [
        "bash", "scripts/generate.sh", "inspect", "--config", publication_fixture / "blueprint-mocking.json",
        "--output", ROOT / ".build/verification/publication-inspect", "--input-set-id", "94",
        "--source", "OfflineDomain", publication_fixture / "Sources/OfflineDomain/Lookup.swift",
    ], env=generation_environment | {"BLUEPRINT_TEST_PUBLICATION_TOOL": "1"})
    publication_fault_tool = tool.with_name("generate-publication-fault")
    run("generation-recovery", [
        sys.executable, "scripts/verify_generation_recovery.py", "--tool", tool, "--fault-tool", publication_fault_tool,
        "--swiftc", swiftc, "--sdk", sdk, "--evidence-dir", EVIDENCE,
    ], env=swift_environment, timeout=180,
        patterns=[r"PASS: DX013 configured output generation preserves and recovers complete pairs",
                  r"EVIDENCE: generation-recovery-report\.json SHA-256 [0-9a-f]{64}"])
    run("generation-contention", [
        sys.executable, "scripts/verify_generation_contention.py", "--tool", tool,
        "--fault-tool", publication_fault_tool, "--evidence-dir", EVIDENCE,
    ], env=swift_environment, timeout=120,
        patterns=[r"PASS: DX013 configured writers serialized and inspection preserved interrupted output",
                  r"EVIDENCE: generation-contention-report\.json SHA-256 [0-9a-f]{64}"])
    for checkpoint, suffix in (("after-shard", ""), ("after-index", "-after-index")):
        lane = "swiftpm-publication-recovery" + suffix
        run(lane, [
            sys.executable, "Fixtures/PluginConsumer/verify_associated_binding.py",
            "--publication-recovery-checkpoint", checkpoint, "--swift", swift,
            "--host-tool", publication_fault_tool, "--evidence-dir", EVIDENCE, "--jobs", "4",
        ], env=swift_environment, timeout=300,
            patterns=[r"PASS: DX013 SwiftPM rejected interrupted publication and ran the recovered pair",
                      rf"EVIDENCE: {lane}-report\.json SHA-256 [0-9a-f]{{64}}"])
    run("swiftpm-first-publication-recovery", [
        sys.executable, "Fixtures/PluginConsumer/verify_associated_binding.py",
        "--first-publication-recovery", "--swift", swift, "--host-tool", publication_fault_tool,
        "--evidence-dir", EVIDENCE, "--jobs", "4",
    ], env=swift_environment, timeout=300,
        patterns=[r"PASS: DX013 SwiftPM recovered its interrupted first publication",
                  r"EVIDENCE: swiftpm-first-publication-recovery-report\.json SHA-256 [0-9a-f]{64}"])
    with tempfile.TemporaryDirectory(prefix="Parser Parity Self Comparison ", dir=EVIDENCE) as directory:
        report = Path(directory) / "parser-parity-report.json"
        report.write_text('{"status":"passed","stale":true}\n')
        placeholder = ROOT / "Packages/Tooling/ExportManifest.json"
        run("reject-parser-parity-self-comparison", [
            sys.executable, "scripts/verify_parser_parity.py", "0" * 40,
            "--bundled-tool", tool, "--packaged-tool", tool,
            "--bundled-receipt", placeholder, "--packaged-receipt", placeholder,
            "--package-resolved", placeholder, "--package-checkout", ROOT, "--package-scratch", ROOT,
            "--syntax-checkout", ROOT, "--evidence-dir", directory,
        ], fails=True, env=swift_environment, patterns=[r"Expected two independent binaries, not a self-comparison"])
        if report.exists():
            raise ValueError("The rejected parser self-comparison left a passing report")
    run("declaration-inspection", [sys.executable, ROOT / "scripts/verify_inspection.py",
                                  "--tool", tool, "--evidence-dir", EVIDENCE],
        patterns=[r"PASS: DX003 read-only inspection", r"PASS: DX011 verify-generated drift checks",
                  r"PASS: DX012 source membership validates listed files and updates only index provenance"])
    run("endpoint-inspection", [sys.executable, ROOT / "scripts/verify_endpoint_inspection.py",
                               "--tool", tool, "--evidence-dir", EVIDENCE],
        patterns=[r"PASS: SYS007 configured inspection reports stable and effect-sensitive endpoint IDs",
                  r"EVIDENCE: endpoint-inspection-report\.json SHA-256 [0-9a-f]{64}"])
    run("configured-generic-method-inspection", [
        sys.executable, "scripts/verify_generic_method_config.py", "--tool", tool, "--evidence-dir", EVIDENCE,
    ], env=swift_environment, patterns=[
        r"PASS: GEN010 configured inspection identifies each typed specialization",
        r"EVIDENCE: generic-method-config-report\.json SHA-256 [0-9a-f]{64}",
    ])
    run("swiftpm-plugin-generic-method", [
        sys.executable, "Fixtures/PluginConsumer/verify_generic_method.py", "--swift", swift,
        "--host-tool", tool, "--evidence-dir", EVIDENCE, "--jobs", "1",
    ], env=swift_environment, timeout=300, patterns=[
        r"PASS: GEN010 configured generic methods compiled and ran through the SwiftPM build plugin",
        r"EVIDENCE: swiftpm-plugin-generic-method-report\.json SHA-256 [0-9a-f]{64}",
    ])
    baseline = generated.read_bytes()
    inherited_source = source.with_name("InheritedDirectory.swift")
    inherited_generated = generated.with_name("InheritedDirectoryMock.swift")
    inherited_parents = tuple(("ConsumerDomain", source.with_name(name + ".swift")) for name in (
        "InheritedDirectoryRoot", "InheritedDirectoryReadBranch", "InheritedDirectoryWriteBranch",
    ))
    run("inherited-protocol-generation", generate(
        tool, inherited_source, inherited_generated, "InheritedDirectory", sources=inherited_parents))
    inherited_mock = inherited_generated.read_text()
    assert len(re.findall(r"(?m)^    public func label\(", inherited_mock)) == 1
    qualified_source = source.with_name("QualifiedDirectory.swift")
    qualified_generated = generated.with_name("QualifiedDirectoryMock.swift")
    qualified_parent = source.parent.parent / "ParentDomain/ForeignSharedDirectory.swift"
    qualified_parents = (("ParentDomain", qualified_parent),)
    run("qualified-inheritance-generation", generate(
        tool, qualified_source, qualified_generated, "QualifiedDirectory", sources=qualified_parents))
    qualified_mock = qualified_generated.read_text()
    assert len(re.findall(r"(?m)^    public func recordForeign\(", qualified_mock)) == 1
    associated_source = source.with_name("AssociatedDirectory.swift")
    associated_generated = generated.with_name("AssociatedDirectoryMock.swift")
    associated_parents = (("ConsumerDomain", source.with_name("AssociatedDirectoryBase.swift")),)
    run("associated-binding-generation", generate(
        tool, associated_source, associated_generated, "AssociatedDirectory",
        sources=associated_parents, associated_bindings=("Element=String",)))
    dependency_associated_source = source.with_name("AssociatedDirectoryFromDependency.swift")
    dependency_associated_generated = generated.with_name("AssociatedDirectoryFromDependencyMock.swift")
    bound_parent = source.parent.parent / "ParentDomain/BoundParent.swift"
    dependency_associated_parents = (("ParentDomain", bound_parent),)
    run("qualified-associated-binding-generation", generate(
        tool, dependency_associated_source, dependency_associated_generated, "AssociatedDirectoryFromDependency",
        sources=dependency_associated_parents, associated_bindings=("Element=String",)))
    parameterized_parent_source = source.with_name("IntDirectory.swift")
    parameterized_parent_generated = generated.with_name("IntDirectoryMock.swift")
    run("parameterized-parent-generation", generate(
        tool, parameterized_parent_source, parameterized_parent_generated, "IntDirectory",
        sources=dependency_associated_parents))
    iterator_source = source.with_name("IntSequence.swift")
    iterator_parent = source.with_name("CursorSequence.swift")
    iterator_alias_source = source.with_name("IntCursor.swift")
    iterator_generated = generated.with_name("IntSequenceMock.swift")
    iterator_sources = (("ConsumerDomain", iterator_parent), ("ConsumerDomain", iterator_alias_source))
    iterator_binding = ("Iterator=ConsumerDomain.IntCursor",)
    iterator_mismatch_source = ROOT / "Fixtures/InheritanceRejections/StringCursorSequence.swift"
    iterator_mismatch_patterns = [
        r"CursorSequence\.swift:3:\d+: error: BPM001: Dependent same-type constraint "
        r"'Iterator\.Element == Element' requires matching types\. ConsumerDomain\.IntCursor\.Element "
        r"is Swift\.Int at .*IntCursor\.swift:2:\d+ and Element is Swift\.String",
    ]
    run("iterator-binding-generation", generate(
        tool, iterator_source, iterator_generated, "IntSequence",
        sources=iterator_sources, associated_bindings=iterator_binding))
    availability_source = source.with_name("AvailabilityDirectory.swift")
    availability_generated = generated.with_name("AvailabilityDirectoryMock.swift")
    run("availability-guarded-member-generation", generate(
        tool, availability_source, availability_generated, "AvailabilityDirectory"))
    availability_mock = availability_generated.read_text()
    availability_gate = re.search(
        r"(?m)^@available\(macOS 14(?:\.0)?, \*\)\n(?=public final class AvailabilityDirectoryMock\b)",
        availability_mock,
    )
    assert availability_gate
    availability_syntax = r"Only @available\(macOS VERSION, \*\) is supported on generated protocol methods"
    actor_source = source.with_name("MainActorDirectory.swift")
    actor_generated = generated.with_name("MainActorDirectoryMock.swift")
    run("main-actor-generation", generate(tool, actor_source, actor_generated, "MainActorDirectory"))
    actor_baseline = actor_generated.read_bytes()

    effect_source = source.with_name("EffectDirectory.swift")
    effect_generated = generated.with_name("EffectDirectoryMock.swift")
    run("effects-generation", generate(tool, effect_source, effect_generated, "EffectDirectory"))

    edge_source = source.with_name("EffectEdges.swift")
    edge_generated = generated.with_name("EffectEdgesMock.swift")
    run("effect-edges-generation", generate(tool, edge_source, edge_generated, "EffectEdges"))

    parameter_source = source.with_name("LookupParameters.swift")
    parameter_generated = generated.with_name("LookupParametersMock.swift")
    run("parameter-list-generation",
        generate(tool, parameter_source, parameter_generated, "LookupParameters"))

    structural_generated = generated.with_name("ValueDirectoryMock.swift")
    run("structural-types-generation",
        generate(tool, parameter_source, structural_generated, "ValueDirectory"))

    property_source = source.with_name("PropertyDirectory.swift")
    property_generated = generated.with_name("PropertyDirectoryMock.swift")
    run("property-accessors-generation",
        generate(tool, property_source, property_generated, "PropertyDirectory"))
    subscript_source = source.with_name("SubscriptDirectory.swift")
    subscript_generated = generated.with_name("SubscriptDirectoryMock.swift")
    run("subscript-generation", generate(tool, subscript_source, subscript_generated, "SubscriptDirectory"))
    effectful_subscript_source = source.with_name("EffectfulSubscriptDirectory.swift")
    effectful_subscript_generated = generated.with_name("EffectfulSubscriptDirectoryMock.swift")
    run("effectful-subscript-generation", generate(
        tool, effectful_subscript_source, effectful_subscript_generated, "EffectfulSubscriptDirectory"))
    spy_source = source.with_name("SpyDirectory.swift")
    spy_generated = generated.with_name("SpyDirectoryMock.swift")
    run("spy-generation", generate(tool, spy_source, spy_generated, "SpyDirectory", spy=True))
    actor_spy_source = source.with_name("ActorSpyDirectory.swift")
    actor_spy_generated = generated.with_name("ActorSpyDirectoryMock.swift")
    run("actor-spy-generation", generate(tool, actor_spy_source, actor_spy_generated, "ActorSpyDirectory", spy=True))
    additional_spies = [
        ("writable-spy", "WritableSpyDirectory"),
        ("actor-writable-spy", "ActorWritableSpyDirectory"),
        ("inout-spy", "InoutSpyDirectory"),
        ("callback-spy", "CallbackSpyDirectory"),
        ("depth-spy", "DepthSpyDirectory"),
        ("structural-spy", "StructuralSpyDirectory"),
    ]
    for check, protocol in additional_spies:
        run(check + "-generation", generate(
            tool, source.with_name(protocol + ".swift"), generated.with_name(protocol + "Mock.swift"),
            protocol, spy=True))
    run("escaping-callback-generation", generate(
        tool, source.with_name("EscapingCallbackDirectory.swift"),
        generated.with_name("EscapingCallbackDirectoryMock.swift"), "EscapingCallbackDirectory"))
    run("actor-escaping-callback-generation", generate(
        tool, source.with_name("ActorEscapingCallbackDirectory.swift"),
        generated.with_name("ActorEscapingCallbackDirectoryMock.swift"), "ActorEscapingCallbackDirectory"))
    run("throwing-escaping-callback-generation", generate(
        tool, source.with_name("ThrowingEscapingCallbackDirectory.swift"),
        generated.with_name("ThrowingEscapingCallbackDirectoryMock.swift"), "ThrowingEscapingCallbackDirectory"))
    run("async-escaping-callback-generation", generate(
        tool, source.with_name("AsyncEscapingCallbackDirectory.swift"),
        generated.with_name("AsyncEscapingCallbackDirectoryMock.swift"), "AsyncEscapingCallbackDirectory"))
    run("async-throwing-escaping-callback-generation", generate(
        tool, source.with_name("AsyncThrowingEscapingCallbackDirectory.swift"),
        generated.with_name("AsyncThrowingEscapingCallbackDirectoryMock.swift"), "AsyncThrowingEscapingCallbackDirectory"))
    run("main-actor-async-escaping-callback-generation", generate(
        tool, source.with_name("MainActorAsyncEscapingCallbackDirectory.swift"),
        generated.with_name("MainActorAsyncEscapingCallbackDirectoryMock.swift"),
        "MainActorAsyncEscapingCallbackDirectory"))
    run("main-actor-throwing-escaping-callback-generation", generate(
        tool, source.with_name("MainActorThrowingEscapingCallbackDirectory.swift"),
        generated.with_name("MainActorThrowingEscapingCallbackDirectoryMock.swift"),
        "MainActorThrowingEscapingCallbackDirectory"))
    run("main-actor-async-throwing-escaping-callback-generation", generate(
        tool, source.with_name("MainActorAsyncThrowingEscapingCallbackDirectory.swift"),
        generated.with_name("MainActorAsyncThrowingEscapingCallbackDirectoryMock.swift"),
        "MainActorAsyncThrowingEscapingCallbackDirectory"))
    run("escaping-callback-configured-rejection", [
        sys.executable, "scripts/verify_escaping_callback_generation.py", "--tool", tool, "--evidence-dir", EVIDENCE,
    ], env=swift_environment, timeout=60,
        patterns=[r"PASS: GEN016 configured generation creates both owned outputs",
                  r"PASS: GEN016 main-actor creates two verified owned outputs",
                  r"PASS: GEN016 qualified-main-actor creates two verified owned outputs",
                  r"PASS: GEN016 typed-throws creates two verified owned outputs",
                  r"PASS: GEN016 async-callback creates two verified owned outputs",
                  r"PASS: GEN016 async-typed-throws creates two verified owned outputs",
                  r"PASS: GEN016 main-actor-async-callback creates two verified owned outputs",
                  r"PASS: GEN016 qualified-main-actor-async-callback creates two verified owned outputs",
                  r"PASS: GEN016 main-actor-typed-throws creates two verified owned outputs",
                  r"PASS: GEN016 qualified-main-actor-typed-throws creates two verified owned outputs",
                  r"PASS: GEN016 main-actor-async-typed-throws creates two verified owned outputs",
                  r"PASS: GEN016 qualified-main-actor-async-typed-throws creates two verified owned outputs",
                  r"EVIDENCE: escaping-callback-generation-report\.json SHA-256 [0-9a-f]{64}"])
    type_subscript_source = source.with_name("TypeSubscriptDirectory.swift")
    type_subscript_generated = generated.with_name("TypeSubscriptDirectoryMock.swift")
    run("type-subscript-generation", generate(
        tool, type_subscript_source, type_subscript_generated, "TypeSubscriptDirectory"))
    generic_method_source = source.with_name("GenericMethodDirectory.swift")
    generic_method_generated = generated.with_name("GenericMethodDirectoryMock.swift")
    method_specializations = ("transform(_:)=Int", "transform(_:)=String")
    run("generic-method-generation", generate(
        tool, generic_method_source, generic_method_generated, "GenericMethodDirectory",
        method_specializations=method_specializations))
    provider_source = source.with_name("GenericProviderDirectory.swift")
    provider_generated = generated.with_name("GenericProviderDirectoryMock.swift")
    provider = ("transform(_:)",)
    run("generic-provider-generation", generate(
        tool, provider_source, provider_generated, "GenericProviderDirectory", generic_providers=provider))
    run("pack-provider-generation", [
        sys.executable, ROOT / "scripts/verify_pack_generation.py", "--tool", tool,
        "--evidence-dir", EVIDENCE / "pack-provider"],
        patterns=[r"PASS: pack provider generation is repeatable and rejects unsupported shapes before publication"])
    built_pack = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/PackProviderDirectoryMock.swift"
    if built_pack.read_bytes() != (EVIDENCE / "pack-provider/PackProviderDirectoryMock.swift").read_bytes():
        raise ValueError("The committed SwiftPM pack fixture differs from standalone generation")
    provider_rejected = temp / "RejectedGenericProvider.swift"
    provider_rejected.write_bytes(b"// preserve existing provider output\n")
    provider_baseline = (provider_rejected.read_bytes(), provider_rejected.stat().st_mtime_ns)
    for label, selectors, types, diagnostic in (
        ("conflict", provider, ("transform(_:)=Int",), "A generic provider and finite specializations cannot both select"),
        ("unknown", ("label(for:)",), (), "Unknown generic provider selector"),
        ("duplicate", provider * 2, (), "Duplicate generic provider selector"),
    ):
        run("generic-provider-reject-" + label, generate(
            tool, provider_source, provider_rejected, "GenericProviderDirectory",
            generic_providers=selectors, method_specializations=types),
            fails=True, patterns=[r"error: BPM001: " + diagnostic])
        if (provider_rejected.read_bytes(), provider_rejected.stat().st_mtime_ns) != provider_baseline:
            raise ValueError("Rejected generic provider settings changed the existing output")
    rethrows_source = source.with_name("RethrowingDirectory.swift")
    rethrows_generated = generated.with_name("RethrowingDirectoryMock.swift")
    rethrows_selector = ("apply(_:)",)
    run("rethrows-provider-generation", generate(
        tool, rethrows_source, rethrows_generated, "RethrowingDirectory", rethrows_providers=rethrows_selector))
    rethrows_pair_source = source.with_name("RethrowingPairDirectory.swift")
    rethrows_pair_generated = generated.with_name("RethrowingPairDirectoryMock.swift")
    run("rethrows-provider-multiple-generation", generate(
        tool, rethrows_pair_source, rethrows_pair_generated, "RethrowingPairDirectory",
        rethrows_providers=("apply(_:fallback:)",)))
    async_rethrows_source = source.with_name("AsyncRethrowingDirectory.swift")
    async_rethrows_generated = generated.with_name("AsyncRethrowingDirectoryMock.swift")
    run("rethrows-provider-async-generation", generate(
        tool, async_rethrows_source, async_rethrows_generated, "AsyncRethrowingDirectory",
        rethrows_providers=rethrows_selector))
    mixed_rethrows_source = source.with_name("MixedRethrowingDirectory.swift")
    mixed_rethrows_generated = generated.with_name("MixedRethrowingDirectoryMock.swift")
    mixed_rethrows_selectors = ("apply(prefix:_:fallback:offset:)", "applyAsync(_:using:prefix:)")
    run("rethrows-provider-mixed-generation", generate(
        tool, mixed_rethrows_source, mixed_rethrows_generated, "MixedRethrowingDirectory",
        rethrows_providers=mixed_rethrows_selectors))
    rejected_rethrows = temp / "RejectedRethrowsProvider.swift"
    rejected_rethrows.write_bytes(b"// preserve valid rethrows output\n")
    rethrows_baseline = (rejected_rethrows.read_bytes(), rejected_rethrows.stat().st_mtime_ns)
    rethrows_cases = [
        ("missing", rethrows_source, (), r"Use --rethrows-provider"),
        ("unknown", rethrows_source, rethrows_selector + ("label(for:)",), r"Unknown rethrows provider selector"),
        ("duplicate", rethrows_source, rethrows_selector * 2, r"Duplicate rethrows provider selector"),
    ]
    authored_rethrows = rethrows_source.read_text(encoding="utf-8")
    for label, signature, selectors, diagnostic in (
        ("bare-async", "func apply(_ callback: (Int) async throws -> String) async rethrows -> String", rethrows_selector,
         r"Async rethrows requires a callback-derived error from unary nonescaping @Sendable"),
        ("escaping-async", "func apply(_ callback: @escaping @Sendable (Int) async throws -> String) async rethrows -> String",
         rethrows_selector, r"Async rethrows requires a callback-derived error from unary nonescaping @Sendable"),
        ("inout", "func apply(_ callback: (Int) throws -> String, fallback: inout String) rethrows -> String",
         ("apply(_:fallback:)",), r"Rethrows requires a callback-derived error from unary"),
    ):
        variant = temp / f"Rethrows-{label}.swift"
        variant.write_text(authored_rethrows.replace(
            "func apply(_ callback: (Int) throws -> String) rethrows -> String", signature,
        ), encoding="utf-8")
        run("rethrows-provider-native-shape-" + label, [swiftc, "-swift-version", "6", "-sdk", sdk, "-typecheck", variant],
            env=swift_environment)
        rethrows_cases.append((label, variant, selectors, diagnostic))
    for label, authored, selectors, diagnostic in rethrows_cases:
        run("rethrows-provider-reject-" + label, generate(
            tool, authored, rejected_rethrows, "RethrowingDirectory", rethrows_providers=selectors),
            fails=True, patterns=[r"error: BPM001:[^\n]*" + diagnostic])
        if (rejected_rethrows.read_bytes(), rejected_rethrows.stat().st_mtime_ns) != rethrows_baseline:
            raise ValueError("Rejected rethrows provider settings changed the existing output")
    fixed_self = ROOT / "Fixtures/GeneratorRejections/FixedSelfDirectory.swift"
    run("fixed-self-native-shape", [swiftc, "-swift-version", "6", "-sdk", sdk, "-typecheck", fixed_self],
        env=swift_environment)
    verify_fluent_self_generation(
        tool, source.with_name("FluentDirectory.swift"), generated.with_name("FluentDirectoryMock.swift"),
        fixed_self, temp)
    verify_lazy_autoclosure_generation(
        tool, source.with_name("LazyChoiceDirectory.swift"), generated.with_name("LazyChoiceDirectoryMock.swift"), temp)
    verify_materialized_autoclosure_generation(
        tool, source.with_name("MaterializedChoiceDirectory.swift"),
        generated.with_name("MaterializedChoiceDirectoryMock.swift"), temp)
    verify_isolated_actor_generation(
        tool, source.with_name("IsolatedActorDirectory.swift"), generated.with_name("IsolatedActorDirectoryMock.swift"),
        temp, [swiftc, "-swift-version", "6", "-sdk", sdk], swift_environment)
    verify_consuming_input_generation(
        tool, source.with_name("ConsumingTicketReceiver.swift"), generated.with_name("ConsumingTicketReceiverMock.swift"),
        temp, [swiftc, "-swift-version", "6", "-sdk", sdk], swift_environment)
    verify_sending_generation(
        tool, source.with_name("SendingPacketDirectory.swift"), generated.with_name("SendingPacketDirectoryMock.swift"), temp)
    verify_owned_result_generation(
        tool, source.with_name("FreshOwnedTicketSource.swift"), generated.with_name("FreshOwnedTicketSourceMock.swift"),
        temp, [swiftc, "-swift-version", "6", "-sdk", sdk], swift_environment)
    verify_byte_buffer_projection_generation(
        tool, source.with_name("SnapshotByteBufferReader.swift"), generated.with_name("SnapshotByteBufferReaderMock.swift"), temp)
    scoped_source = source.with_name("ScopedUserDirectory.swift")
    scoped_generated = generated.with_name("ScopedUserDirectoryMock.swift")
    run("scoped-rule-generation", generate(
        tool, scoped_source, scoped_generated, "ScopedUserDirectory", scoped_rules=("fetch(id:)",)))
    scoped_rejected = temp / "RejectedScopedRules.swift"
    scoped_rejected.write_bytes(scoped_generated.read_bytes())
    scoped_baseline = (scoped_rejected.read_bytes(), scoped_rejected.stat().st_mtime_ns)
    start, end = scoped_source.read_text(encoding="utf-8").rsplit("}", 1)
    scoped_collision = temp / "ScopePropertyCollision.swift"
    scoped_collision.write_text(start + "    var ruleScopes: Int { get }\n}" + end, encoding="utf-8")
    for label, authored, selectors, diagnostic in (
        ("wrong-effect", scoped_source, ("label(for:)",), r"requires an async-throwing instance method"),
        ("unknown", scoped_source, ("missing(id:)",), r"Unknown scoped rule selector"),
        ("duplicate", scoped_source, ("fetch(id:)",) * 2, r"Duplicate scoped rule selector"),
        ("property-collision", scoped_collision, ("fetch(id:)",), r"conflicts with generated 'ruleScopes' or 'RuleScopes'"),
    ):
        run("scoped-rule-reject-" + label, generate(
            tool, authored, scoped_rejected, "ScopedUserDirectory", scoped_rules=selectors),
            fails=True, patterns=[diagnostic])
        if (scoped_rejected.read_bytes(), scoped_rejected.stat().st_mtime_ns) != scoped_baseline:
            raise ValueError("Rejected scoped-rule generation modified valid output")
    generic_subscript_source = source.with_name("GenericSubscriptDirectory.swift")
    generic_subscript_generated = generated.with_name("GenericSubscriptDirectoryMock.swift")
    generic_subscript_specializations = ("get_subscript(_:)=Int", "get_subscript(_:)=String",
                                         "get_subscript(_:)=Int?", "get_subscript(named:)=Int")
    run("generic-subscript-generation", generate(
        tool, generic_subscript_source, generic_subscript_generated, "GenericSubscriptDirectory",
        specializations=generic_subscript_specializations))
    variadic_subscript_source = source.with_name("VariadicSubscriptDirectory.swift")
    variadic_subscript_generated = generated.with_name("VariadicSubscriptDirectoryMock.swift")
    variadic_subscript_forwarding = ("get_subscript(field:_:)", "set_subscript(field:_:newValue:)",
                                    "get_subscript(remote:_:)")
    run("variadic-subscript-generation", generate(
        tool, variadic_subscript_source, variadic_subscript_generated, "VariadicSubscriptDirectory",
        forwarding=variadic_subscript_forwarding))
    variadic_source = source.with_name("VariadicDirectory.swift")
    variadic_generated = generated.with_name("VariadicDirectoryMock.swift")
    variadic_forwarding = ("sample(_:)", "names(in:ids:fallback:)")
    run("variadic-generation", generate(
        tool, variadic_source, variadic_generated, "VariadicDirectory", forwarding=variadic_forwarding))
    variadic_projected = generated.with_name("VariadicDirectoryProjectedMock.swift")
    run("projected-variadic-forwarding-generation", generate(
        tool, variadic_source, variadic_projected, "VariadicDirectory",
        projections=("sample(_:)",), forwarding=("sample(_:)",)))
    temp = ROOT / ".build/verification"
    temp.mkdir(parents=True, exist_ok=True)
    result_source = source.with_name("ResultOverloadDirectory.swift")
    result_mock = generated.with_name("ResultOverloadDirectoryMock.swift")
    run("return-only-overload-generation", generate(
        tool, result_source, result_mock, "ResultOverloadDirectory"))
    immediate_source = source.with_name("CallbackSpyDirectory.swift")
    immediate_generated = generated.with_name("ImmediateCallbackDirectoryMock.swift")
    run("immediate-callback-generation", generate(
        tool, immediate_source, immediate_generated, "ImmediateCallbackDirectory"))
    immediate_config = temp / "immediate-callback-config.json"
    immediate_config.write_text(json.dumps({"schemaVersion": 1, "selections": [
        {"module": "ConsumerDomain", "type": "ImmediateCallbackDirectory", "kind": "protocol"},
    ]}), encoding="utf-8")
    immediate_output = temp / "immediate-callback-configured"
    immediate_args = [
        "--config", immediate_config, "--output", immediate_output, "--input-set-id", "120",
        "--source", "ConsumerDomain", immediate_source,
    ]
    run("immediate-callback-configured-generation", [tool, "generate", *immediate_args])
    shard = (immediate_output / "BlueprintMocks.generated.swift").read_bytes()
    header = b"// Generated by Blueprint Mocking. Do not edit.\n"
    if not shard.startswith(header + immediate_generated.read_bytes() + b"\nenum BlueprintMockingShard_"):
        raise ValueError("Configured and standalone immediate callback witnesses differ")
    run("immediate-callback-verify-generated", [tool, "verify-generated", *immediate_args])

    scoped_function_shape = (
        r"Nonescaping callback plans require an unannotated unary synchronous nonthrowing function argument"
    )
    scoped_method_shape = (
        r"Nonescaping callback plans require a synchronous nonthrowing Sendable method with one callback in the final position"
    )
    for case, protocol_prefix, requirement, diagnostic in (
        ("actor-witness", "@MainActor ", "func run(_ callback: (Int) -> String) -> String", scoped_function_shape),
        ("async-function", "", "func run(_ callback: (Int) async -> String) -> String", scoped_function_shape),
        ("async-witness", "", "func run(_ callback: (Int) -> String) async -> String", scoped_method_shape),
        ("non-final", "", "func run(_ callback: (Int) -> String, id: String) -> String", scoped_method_shape),
    ):
        boundary = temp / f"immediate-callback-{case}.swift"
        inherited = ": Sendable" if not protocol_prefix else ""
        boundary.write_text(
            f"{protocol_prefix}public protocol ImmediateCallbackBoundary{inherited} {{\n    {requirement}\n}}\n"
        )
        run("reject-immediate-callback-" + case, generate(
            tool, boundary, boundary.with_suffix(".generated.swift"), "ImmediateCallbackBoundary"),
            fails=True, patterns=[r"error: BPM001: " + diagnostic])

    ordinary_inout_source = source.with_name("InoutSpyDirectory.swift")
    ordinary_inout_generated = generated.with_name("OrdinaryInoutDirectoryMock.swift")
    run("ordinary-inout-generation", generate(
        tool, ordinary_inout_source, ordinary_inout_generated, "OrdinaryInoutDirectory"))
    ordinary_inout_config = temp / "ordinary-inout-config.json"
    ordinary_inout_config.write_text(json.dumps({"schemaVersion": 1, "selections": [
        {"module": "ConsumerDomain", "type": "OrdinaryInoutDirectory", "kind": "protocol"},
    ]}), encoding="utf-8")
    ordinary_inout_output = temp / "ordinary-inout-configured"
    ordinary_inout_args = [
        "--config", ordinary_inout_config, "--output", ordinary_inout_output, "--input-set-id", "123",
        "--source", "ConsumerDomain", ordinary_inout_source,
    ]
    run("ordinary-inout-configured-generation", [tool, "generate", *ordinary_inout_args])
    shard = (ordinary_inout_output / "BlueprintMocks.generated.swift").read_bytes()
    if not shard.startswith(header + ordinary_inout_generated.read_bytes() + b"\nenum BlueprintMockingShard_"):
        raise ValueError("Configured and standalone ordinary inout witnesses differ")
    run("ordinary-inout-verify-generated", [tool, "verify-generated", *ordinary_inout_args])

    inout_parameter_shape = r"Use named, optional, array or dictionary parameter types without ownership"
    ordinary_inout_boundaries = (
        ("async", "", "Sendable", "(_ value: inout Swift.Int) async",
         r"Ordinary inout stubbing requires a synchronous method"),
        ("actor", "@MainActor ", "", "(_ value: inout Swift.Int)", inout_parameter_shape),
        ("unqualified", "", "Sendable", "(_ value: inout Int)", inout_parameter_shape),
        ("multiple", "", "Sendable", "(_ value: inout Swift.Int, other: Swift.Int)", inout_parameter_shape),
        ("shadowed-swift", "public enum Swift { public typealias Int = String }\n", "Sendable",
         "(_ value: inout Swift.Int)", r"'Swift' is shadowed by a local declaration"),
    )
    for case, prefix, conformance, signature, diagnostic in ordinary_inout_boundaries:
        boundary = temp / f"ordinary-inout-{case}.swift"
        inheritance = f": {conformance}" if conformance else ""
        boundary.write_text(
            f"{prefix}public protocol OrdinaryInoutBoundary{inheritance} {{\n    func update{signature}\n}}\n"
        )
        run("reject-ordinary-inout-" + case, generate(
            tool, boundary, boundary.with_suffix(".generated.swift"), "OrdinaryInoutBoundary"),
            fails=True, patterns=[r"error: BPM001: .*" + diagnostic])

    adapter_source = source.with_name("CheckoutAdapters.swift")
    for selected, check in (("CatalogPricing", "catalog-pricing-adapter"),
                            ("BasketDiscount", "basket-discount-adapter"),
                            ("SKUFormatting", "sku-formatting-adapter")):
        expected = generated.with_name(selected + "Mock.swift")
        regenerated = temp / expected.name
        run(check + "-generation", generate(tool, adapter_source, regenerated, selected))
        run(check + "-output", ["cmp", expected, regenerated])
    verify_conditional_generation(tool, temp)
    availability_config_source = temp / availability_source.name
    authored_availability = availability_source.read_text()
    availability_config_source.write_text(authored_availability)
    availability_config = temp / "availability-blueprint-mocking.json"
    availability_config.write_text(json.dumps({
        "schemaVersion": 1,
        "selections": [{"module": "ConsumerDomain", "type": "AvailabilityDirectory", "kind": "protocol"}],
    }))
    availability_batch = temp / "availability-batch"
    availability_config_command = [
        tool, "generate", "--config", availability_config, "--output", availability_batch, "--input-set-id", "7",
        "--source", "ConsumerDomain", availability_config_source,
    ]
    run("availability-config-generation", availability_config_command,
        patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
    availability_outputs = [
        availability_batch / "BlueprintMocks.generated.swift", availability_batch / "BlueprintMockingIndex.generated.swift",
    ]
    assert availability_generated.read_bytes() in availability_outputs[0].read_bytes()
    original_availability_outputs = [(file.read_bytes(), file.stat().st_mtime_ns) for file in availability_outputs]
    supported_receipt = "@available(macOS 14.0, *)\n    func receipt() -> NewReceipt"
    assert authored_availability.count(supported_receipt) == 1
    availability_config_source.write_text(authored_availability.replace(
        supported_receipt, "@available(macOS 14.0, iOS 17.0, *)\n    func receipt() -> NewReceipt",
    ))
    run("reject-availability-config-method-syntax", availability_config_command,
        fails=True, patterns=[r"BPM001: " + availability_syntax])
    assert [(file.read_bytes(), file.stat().st_mtime_ns) for file in availability_outputs] == original_availability_outputs

    availability_order_source = temp / "OrderedAvailability.swift"
    availability_order_output = temp / "OrderedAvailabilityMock.swift"
    availability_members = [("EarlyReceipt", "early", "14.0"), ("LateReceipt", "late", "15.0.2")]
    availability_payloads = [
        f"@available(macOS {version}, *) public struct {payload}: Swift.Sendable {{}}"
        for payload, _, version in availability_members
    ]
    for label, members in (("later-last", availability_members), ("later-first", reversed(availability_members))):
        availability_methods = [
            f"    @available(macOS {version}, *) func {name}() -> {payload}"
            for payload, name, version in members
        ]
        availability_order_source.write_text("\n".join([
            *availability_payloads, "public protocol OrderedAvailability: Swift.Sendable {",
            *availability_methods, "}", "",
        ]))
        run("availability-max-introduction-" + label, generate(
            tool, availability_order_source, availability_order_output, "OrderedAvailability"))
        assert re.search(r"(?m)^@available\(macOS 15\.0\.2, \*\)\npublic final class OrderedAvailabilityMock\b",
                         availability_order_output.read_text())
    run("generation-repeat", generate(tool, source, temp / "Repeated.swift"))

    repeated_inheritance = temp / "RepeatedInherited.swift"
    run("inherited-protocol-generation-reordered", generate(
        tool, inherited_source, repeated_inheritance, "InheritedDirectory", sources=reversed(inherited_parents)))
    assert repeated_inheritance.read_text() == inherited_mock
    inherited_config = temp / "inherited-blueprint-mocking.json"
    inherited_config.write_text(json.dumps({
        "schemaVersion": 1,
        "selections": [{"module": "ConsumerDomain", "type": "InheritedDirectory", "kind": "protocol"}],
    }))
    inherited_batch = temp / "inherited-batch"
    batch_inputs = [value for module, path in (*inherited_parents, ("ConsumerDomain", inherited_source))
                    for value in ("--source", module, path)]
    run("inherited-protocol-generation-config", [
        tool, "generate", "--config", inherited_config, "--output", inherited_batch,
        "--input-set-id", "1", *batch_inputs], patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
    assert inherited_mock in (inherited_batch / "BlueprintMocks.generated.swift").read_text()
    previous_batch = {file.name: file.read_bytes() for file in inherited_batch.glob("*.generated.swift")}
    run("reject-inheritance-config-missing", [
        tool, "generate", "--config", inherited_config, "--output", inherited_batch,
        "--input-set-id", "1", "--source", "ConsumerDomain", inherited_source],
        fails=True, patterns=[r"BPM001: Missing inherited protocol ConsumerDomain\.InheritedDirectoryReadBranch"])
    assert {file.name: file.read_bytes() for file in inherited_batch.glob("*.generated.swift")} == previous_batch
    qualified_config = temp / "qualified-blueprint-mocking.json"
    qualified_config.write_text(json.dumps({
        "schemaVersion": 1,
        "selections": [{"module": "ConsumerDomain", "type": "QualifiedDirectory", "kind": "protocol"}],
    }))
    qualified_batch = temp / "qualified-batch"
    qualified_inputs = (*qualified_parents, ("ConsumerDomain", qualified_source))
    qualified_outputs = []
    for label, inputs in (("config", qualified_inputs), ("config-reordered", reversed(qualified_inputs))):
        run("qualified-inheritance-generation-" + label, [
            tool, "generate", "--config", qualified_config, "--output", qualified_batch,
            "--input-set-id", "2", *(value for module, path in inputs for value in ("--source", module, path)),
        ], patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
        assert qualified_mock in (qualified_batch / "BlueprintMocks.generated.swift").read_text()
        qualified_outputs.append(tuple((qualified_batch / name).read_bytes() for name in (
            "BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift",
        )))
    assert qualified_outputs[0] == qualified_outputs[1]
    qualified_binding = temp / "RepeatedAssociatedBinding.swift"
    run("associated-binding-generation-qualified", generate(
        tool, associated_source, qualified_binding, "AssociatedDirectory",
        sources=associated_parents, associated_bindings=("Element=Swift.String",)))
    assert qualified_binding.read_bytes() == associated_generated.read_bytes()
    associated_config = temp / "associated-blueprint-mocking.json"
    associated_selection = {
        "module": "ConsumerDomain", "type": "AssociatedDirectory", "kind": "protocol",
        "associatedTypeBindings": [{"name": "Element", "type": "String"}],
    }
    associated_config.write_text(json.dumps({"schemaVersion": 1, "selections": [associated_selection]}))
    associated_batch = temp / "associated-config-batch"
    associated_config_args = [
        "--config", associated_config, "--output", associated_batch, "--input-set-id", "3",
        "--source", "ConsumerDomain", associated_source,
        "--source", "ConsumerDomain", associated_parents[0][1],
    ]
    associated_inspection = json.loads(run("associated-config-inspection", [
        tool, "inspect", *associated_config_args, "--format", "json",
    ]))
    normalized_selection, = associated_inspection["configuration"]["selections"]
    assert normalized_selection == associated_selection | {
        "associatedTypeBindings": [{"name": "Element", "type": "Swift.String"}],
    }
    run("associated-config-generation", [tool, "generate", *associated_config_args],
        patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
    assert associated_generated.read_text() in (associated_batch / "BlueprintMocks.generated.swift").read_text()
    last_valid_associated_outputs = {
        file.name: file.read_bytes() for file in associated_batch.glob("*.generated.swift")
    }
    run("associated-config-verify-generated", [tool, "verify-generated", *associated_config_args],
        patterns=[r"Blueprint Mocking: verified 2 generated file"])
    binding, = associated_selection["associatedTypeBindings"]
    invalid_selection = associated_selection | {"associatedTypeBindings": [binding | {"typo": True}]}
    associated_config.write_text(json.dumps({"schemaVersion": 1, "selections": [invalid_selection]}))
    run("reject-associated-config-binding-shape", [tool, "generate", *associated_config_args],
        fails=True, patterns=[r"BPM002: Expected associatedTypeBindings to contain name and type strings"])
    conflicting_selection = associated_selection | {
        "associatedTypeBindings": [binding, {"name": "Element", "type": "Int"}],
    }
    associated_config.write_text(json.dumps({"schemaVersion": 1, "selections": [conflicting_selection]}))
    run("reject-associated-config-conflict", [tool, "verify-generated", *associated_config_args],
        fails=True, patterns=[r"BPM001: Conflicting explicit bindings for associated type 'Element'"])
    assert {file.name: file.read_bytes() for file in associated_batch.glob("*.generated.swift")} == (
        last_valid_associated_outputs
    )
    dependency_config = temp / "qualified-associated-blueprint-mocking.json"
    dependency_selection = associated_selection | {"type": "AssociatedDirectoryFromDependency"}
    dependency_config.write_text(json.dumps({"schemaVersion": 1, "selections": [dependency_selection]}))
    dependency_batch = temp / "qualified-associated-config-batch"
    dependency_config_args = [
        "--config", dependency_config, "--output", dependency_batch, "--input-set-id", "4",
        "--source", "ConsumerDomain", dependency_associated_source, "--source", "ParentDomain", bound_parent,
    ]
    run("qualified-associated-config-generation", [tool, "generate", *dependency_config_args],
        patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
    assert dependency_associated_generated.read_bytes() in (
        dependency_batch / "BlueprintMocks.generated.swift"
    ).read_bytes()
    run("qualified-associated-config-verify-generated", [tool, "verify-generated", *dependency_config_args],
        patterns=[r"Blueprint Mocking: verified 2 generated file"])
    explicit_parameterized_parent = temp / "RepeatedParameterizedParent.swift"
    run("parameterized-parent-explicit-parity", generate(
        tool, parameterized_parent_source, explicit_parameterized_parent, "IntDirectory",
        sources=dependency_associated_parents, associated_bindings=("Element=Int",)))
    assert explicit_parameterized_parent.read_bytes() == parameterized_parent_generated.read_bytes()
    parameterized_config = temp / "parameterized-parent-blueprint-mocking.json"
    parameterized_selection = {"module": "ConsumerDomain", "type": "IntDirectory", "kind": "protocol"}
    parameterized_config.write_text(json.dumps({"schemaVersion": 1, "selections": [parameterized_selection]}))
    parameterized_batch = temp / "parameterized-parent-batch"
    parameterized_config_args = [
        "--config", parameterized_config, "--output", parameterized_batch, "--input-set-id", "5",
        "--source", "ConsumerDomain", parameterized_parent_source, "--source", "ParentDomain", bound_parent,
    ]
    parameterized_inspection = json.loads(run("parameterized-parent-config-inspection", [
        tool, "inspect", *parameterized_config_args, "--format", "json",
    ]))
    assert parameterized_inspection["configuration"]["selections"] == [parameterized_selection | {
        "associatedTypeBindings": [{"name": "Element", "type": "Swift.Int"}],
    }]
    run("parameterized-parent-config-generation", [tool, "generate", *parameterized_config_args],
        patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
    assert parameterized_parent_generated.read_bytes() in (
        parameterized_batch / "BlueprintMocks.generated.swift"
    ).read_bytes()
    run("parameterized-parent-config-verify-generated", [tool, "verify-generated", *parameterized_config_args],
        patterns=[r"Blueprint Mocking: verified 2 generated file"])
    iterator_config = temp / "iterator-binding-blueprint-mocking.json"
    iterator_selection = {
        "module": "ConsumerDomain", "type": "IntSequence", "kind": "protocol",
        "associatedTypeBindings": [{"name": "Iterator", "type": "ConsumerDomain.IntCursor"}],
    }
    iterator_config.write_text(json.dumps({"schemaVersion": 1, "selections": [iterator_selection]}))
    iterator_batch = temp / "iterator-binding-batch"
    iterator_config_args = [
        "--config", iterator_config, "--output", iterator_batch, "--input-set-id", "6",
        "--source", "ConsumerDomain", iterator_source,
        "--source", "ConsumerDomain", iterator_mismatch_source,
        *(argument for module, path in iterator_sources for argument in ("--source", module, path)),
    ]
    iterator_inspection = json.loads(run("iterator-binding-config-inspection", [
        tool, "inspect", *iterator_config_args, "--format", "json",
    ]))
    assert iterator_inspection["configuration"]["selections"] == [iterator_selection | {
        "associatedTypeBindings": [
            {"name": "Element", "type": "Swift.Int"},
            {"name": "Iterator", "type": "ConsumerDomain.IntCursor"},
        ],
    }]
    run("iterator-binding-config-generation", [tool, "generate", *iterator_config_args],
        patterns=[r"Blueprint Mocking: generated 1 protocol mock"])
    assert iterator_generated.read_bytes() in (iterator_batch / "BlueprintMocks.generated.swift").read_bytes()
    run("iterator-binding-config-verify-generated", [tool, "verify-generated", *iterator_config_args],
        patterns=[r"Blueprint Mocking: verified 2 generated file"])
    iterator_outputs = [
        iterator_batch / "BlueprintMocks.generated.swift", iterator_batch / "BlueprintMockingIndex.generated.swift",
    ]
    original_iterator_outputs = [(file.read_bytes(), file.stat().st_mtime_ns) for file in iterator_outputs]
    incompatible_iterator_selection = iterator_selection | {"type": "StringCursorSequence"}
    iterator_config.write_text(json.dumps({"schemaVersion": 1, "selections": [incompatible_iterator_selection]}))
    run("reject-iterator-binding-config-mismatch", [tool, "generate", *iterator_config_args],
        fails=True, patterns=iterator_mismatch_patterns)
    assert [(file.read_bytes(), file.stat().st_mtime_ns) for file in iterator_outputs] == original_iterator_outputs
    assert baseline == (temp / "Repeated.swift").read_bytes()
    actor_repeated = temp / "RepeatedMainActor.swift"
    run("main-actor-generation-repeat",
        generate(tool, actor_source, actor_repeated, "MainActorDirectory"))
    assert actor_baseline == actor_repeated.read_bytes()
    relocated = temp / "relocated"
    relocated.mkdir(exist_ok=True)
    relocated_source = relocated / source.name
    relocated_source.write_text(source.read_text().replace(
        "func greeting(for name: String)", "func   greeting( for name : String )"))
    run("generation-whitespace", generate(tool, relocated_source, temp / "Whitespace.swift"))
    assert baseline == (temp / "Whitespace.swift").read_bytes()
    relocated_subscript = relocated / subscript_source.name
    relocated_subscript.write_text(subscript_source.read_text().replace(
        "subscript(row: Int, column: Int)", "subscript(_ renamedRow: Int, _ renamedColumn: Int)"))
    repeated_subscript = temp / "RepeatedSubscript.swift"
    run("subscript-label-normalization", generate(
        tool, relocated_subscript, repeated_subscript, "SubscriptDirectory"))
    assert subscript_generated.read_bytes() == repeated_subscript.read_bytes()
    repeated_spy = temp / "RepeatedSpy.swift"
    run("spy-generation-repeat", generate(tool, spy_source, repeated_spy, "SpyDirectory", spy=True))
    assert spy_generated.read_bytes() == repeated_spy.read_bytes()
    repeated_actor_spy = temp / "RepeatedActorSpy.swift"
    run("actor-spy-generation-repeat", generate(tool, actor_spy_source, repeated_actor_spy, "ActorSpyDirectory", spy=True))
    assert actor_spy_generated.read_bytes() == repeated_actor_spy.read_bytes()
    for check, protocol in additional_spies:
        repeated = temp / ("Repeated" + protocol + ".swift")
        run(check + "-generation-repeat", generate(
            tool, source.with_name(protocol + ".swift"), repeated, protocol, spy=True))
        assert generated.with_name(protocol + "Mock.swift").read_bytes() == repeated.read_bytes()
    repeated_type_subscript = temp / "RepeatedTypeSubscript.swift"
    run("type-subscript-generation-repeat", generate(
        tool, type_subscript_source, repeated_type_subscript, "TypeSubscriptDirectory"))
    assert type_subscript_generated.read_bytes() == repeated_type_subscript.read_bytes()
    rejected_type_projection = temp / "RejectedTypeSubscriptProjection.swift"
    sentinel = "sentinel: preserve generated output\n"
    rejected_type_projection.write_text(sentinel)
    run("type-subscript-reject-projection", generate(
        tool, type_subscript_source, rejected_type_projection, "TypeSubscriptDirectory",
        projections=("get_subscript(_:)",)), fails=True,
        patterns=[r"BPM001", r":\d+:\d+: error:", r"cannot be combined with generated projected mock types"])
    assert rejected_type_projection.read_text() == sentinel
    repeated_generic_method = temp / "RepeatedGenericMethod.swift"
    run("generic-method-generation-repeat", generate(
        tool, generic_method_source, repeated_generic_method, "GenericMethodDirectory",
        method_specializations=("transform(_:)=Swift.String", "transform(_:)=Swift.Int")))
    run("generic-method-generation-repeat-compare", ["cmp", generic_method_generated, repeated_generic_method])
    invalid_generic_method = temp / "RejectedGenericMethod.swift"
    method_sentinel = b"// existing Swift output\n"
    for label, options, diagnostic in (
        ("missing", (), r"Generic methods require explicit specialization"),
        ("duplicate", ("transform(_:)=Int", "transform(_:)=Swift.Int"), r"Duplicate generic method specialization"),
        ("selector", ("unrelated(_:)=Int",), r"Unknown generic method selector"),
        ("type", ("transform(_:)=Bool",), r"Unsupported generic method specialization type 'Bool'"),
    ):
        invalid_generic_method.write_bytes(method_sentinel)
        initial_mtime = invalid_generic_method.stat().st_mtime_ns
        run("generic-method-reject-" + label, generate(
            tool, generic_method_source, invalid_generic_method, "GenericMethodDirectory",
            method_specializations=options), fails=True, patterns=[r"error: BPM001: " + diagnostic])
        if (invalid_generic_method.read_bytes(), invalid_generic_method.stat().st_mtime_ns) != (method_sentinel, initial_mtime):
            raise ValueError("Rejected generic method options changed the existing output")

    generic_body = generic_method_source.read_text(encoding="utf-8")
    for label, original, edited, diagnostic in (
        ("constraints", "Hashable & Sendable", "Equatable & Sendable",
         r"Generic method specialization requires inline Hashable and Sendable constraints"),
        ("async", "(_ value: T) -> T", "(_ value: T) async -> T",
         r"Generic method specialization requires a direct synchronous nonthrowing Sendable requirement"),
    ):
        boundary = temp / f"GenericMethod-{label}.swift"
        boundary.write_text(generic_body.replace(original, edited), encoding="utf-8")
        run("generic-method-reject-" + label, generate(
            tool, boundary, invalid_generic_method, "GenericMethodDirectory",
            method_specializations=method_specializations), fails=True, patterns=[r"error: BPM001: " + diagnostic])

    repeated_generic_subscript = temp / "RepeatedGenericSubscript.swift"
    run("generic-subscript-generation-repeat", generate(
        tool, generic_subscript_source, repeated_generic_subscript, "GenericSubscriptDirectory",
        specializations=reversed(generic_subscript_specializations)))
    assert generic_subscript_generated.read_bytes() == repeated_generic_subscript.read_bytes()
    generic_rejections = (
        ("unknown", ("get_subscript(wrong:)=Int",), "Unknown generic subscript selector"),
        ("duplicate", ("get_subscript(_:)=Int?", "get_subscript(_:) = Int?"),
         "Duplicate generic subscript specialization"),
        ("unsupported-type", ("get_subscript(_:)=(Int, String)",),
         "Unsupported generic subscript specialization type"),
        ("missing-declaration", ("get_subscript(_:)=Int",),
         "Generic subscripts require explicit specialization"),
    )
    for label, options, pattern in generic_rejections:
        rejected = temp / "RejectedGenericSubscript.swift"
        sentinel = "sentinel: preserve generated output\n"
        rejected.write_text(sentinel)
        run("generic-subscript-reject-" + label, generate(
            tool, generic_subscript_source, rejected, "GenericSubscriptDirectory", specializations=options),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == sentinel
    repeated_variadic_subscript = temp / "RepeatedVariadicSubscript.swift"
    run("variadic-subscript-generation-repeat", generate(
        tool, variadic_subscript_source, repeated_variadic_subscript, "VariadicSubscriptDirectory",
        forwarding=reversed(variadic_subscript_forwarding)))
    assert variadic_subscript_generated.read_bytes() == repeated_variadic_subscript.read_bytes()
    repeated_variadic = temp / "RepeatedVariadic.swift"
    run("variadic-generation-repeat", generate(
        tool, variadic_source, repeated_variadic, "VariadicDirectory",
        forwarding=reversed(variadic_forwarding)))
    assert variadic_generated.read_bytes() == repeated_variadic.read_bytes()
    projection_protocol = "GeneratedProjectionDirectory"
    projection_source = source.with_name(projection_protocol + ".swift")
    projection_output = generated.with_name(projection_protocol + "ProjectedMock.swift")
    projection_members = ("fetch(id:)", "read(id:)")
    run("projection-generation", generate(
        tool, projection_source, projection_output, projection_protocol, projection_members))
    repeated_projection = temp / "RepeatedProjection.swift"
    run("projection-generation-repeat", generate(
        tool, projection_source, repeated_projection, projection_protocol, reversed(projection_members)))
    assert projection_output.read_bytes() == repeated_projection.read_bytes()

    ambiguous = temp / "AmbiguousProjection.swift"
    ambiguous.write_text(
        "public protocol AmbiguousProjection: Sendable {\n"
        "    func fetch(id: Int) -> String\n"
        "    func fetch(id: String) -> String\n"
        "}\n"
    )
    projection_rejections = (
        ("unknown", projection_source, projection_protocol, ("missing(id:)",), "Unknown projection selector"),
        ("duplicate", projection_source, projection_protocol, (projection_members[0],) * 2,
         "Duplicate projection selector"),
        ("actor", actor_source, "MainActorDirectory", ("display(id:)",), "require a Sendable protocol"),
        ("effect", effect_source, "EffectDirectory", ("refreshedName(id:)",),
         "requires a synchronous nonthrowing or async-throwing method"),
        ("ambiguous", ambiguous, "AmbiguousProjection", ("fetch(id:)",), "Ambiguous projection selector"),
    )
    for label, input_path, protocol, selectors, pattern in projection_rejections:
        rejected = temp / "RejectedProjection.swift"
        previous = "sentinel: preserve the previous projection generation\n"
        rejected.write_text(previous)
        run("projection-reject-" + label, generate(tool, input_path, rejected, protocol, selectors),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == previous
    canonical = "schema1|ConsumerDomain.AmbiguousProjection|fetch(id:Int)->String|Sendable"
    disambiguated = temp / "DisambiguatedProjection.swift"
    run("projection-canonical-selector", generate(
        tool, ambiguous, disambiguated, "AmbiguousProjection", (canonical,)))
    assert "ProjectedSyncEndpoint<Int, String," in disambiguated.read_text()
    spy_inout = temp / "InoutSpy.swift"
    spy_inout.write_text("public protocol InoutSpy: Sendable { func update(_ value: inout String) }\n")
    spy_async_inout = temp / "AsyncInoutSpy.swift"
    spy_async_inout.write_text("public protocol AsyncInoutSpy: Sendable { func update(_ value: inout Int) async }\n")
    spy_actor_inout = temp / "ActorInoutSpy.swift"
    spy_actor_inout.write_text("@MainActor public protocol ActorInoutSpy { func update(_ value: inout Int) }\n")
    spy_inout_collision = temp / "InoutSpyCollision.swift"
    spy_inout_collision.write_text("public protocol InoutSpyCollision: Sendable {\n"
                                   "    func update(_ value: Int)\n"
                                   "    func update(_ value: inout Int)\n"
                                   "}\n")
    spy_callback = temp / "CallbackSpy.swift"
    spy_callback.write_text("public protocol CallbackSpy: Sendable { func apply(_ block: @escaping (Int) -> Int) }\n")
    spy_actor_callback = temp / "MainActorCallbackSpy.swift"
    spy_actor_callback.write_text("public protocol MainActorCallbackSpy: Sendable {\n"
                                  "    func apply(_ block: @MainActor (Int) -> Int)\n"
                                  "}\n")
    spy_async_callback = temp / "AsyncCallbackSpy.swift"
    spy_async_callback.write_text("public protocol AsyncCallbackSpy: Sendable { func apply(_ block: (Int) -> Int) async }\n")
    spy_callback_collision = temp / "CallbackSpyCollision.swift"
    spy_callback_collision.write_text("public protocol CallbackSpyCollision: Sendable {\n"
                                      "    func apply(id: Int, using block: (Int) -> Int) -> Int\n"
                                      "    func apply(id: Int) -> Int\n"
                                      "}\n")
    spy_link_collision = temp / "SpyLinkCollision.swift"
    spy_link_collision.write_text("public protocol SpyLinkCollision: Sendable {\n"
                                  "    var forwardingTargets: Int { get }\n"
                                  "    func probe() async throws -> Int\n"
                                  "}\n")
    spy_rejections = (
        ("link-name-collision", spy_link_collision, "SpyLinkCollision", (),
         "conflicts with generated forwarding link setup or target names"),
        ("variadic", variadic_source, "VariadicDirectory", (), "cannot splat a Swift variadic argument"),
        ("writable-property", property_source, "PropertyDirectory", (), "writable property requires a nonmutating setter"),
        ("writable-subscript", subscript_source, "SubscriptDirectory", (), "writable subscript requires a nonmutating setter"),
        ("static", type_subscript_source, "TypeSubscriptDirectory", (), "use a metatype seam"),
        ("generic", generic_subscript_source, "GenericSubscriptDirectory", (), "requires a polymorphic provider"),
        ("projection", spy_source, "SpyDirectory", ("display(for:)",), "cannot be combined with projections"),
        ("inout-type", spy_inout, "InoutSpy", (), "requires a Sendable method with one inout Swift.Int"),
        ("inout-async", spy_async_inout, "AsyncInoutSpy", (), "inout forwarding requires a synchronous method"),
        ("inout-actor", spy_actor_inout, "ActorInoutSpy", (), "requires a Sendable method with one inout Swift.Int"),
        ("inout-collision", spy_inout_collision, "InoutSpyCollision", (), "Inout overloads with identical matcher signatures"),
        ("callback-escaping", spy_callback, "CallbackSpy", (), "require one unannotated, nonescaping"),
        ("callback-isolated", spy_actor_callback, "MainActorCallbackSpy", (), "require one unannotated, nonescaping"),
        ("callback-async", spy_async_callback, "AsyncCallbackSpy", (), "require a synchronous nonthrowing method"),
        ("callback-collision", spy_callback_collision, "CallbackSpyCollision", (), "identical ordinary-argument matcher signatures"),
    )
    for label, input_path, protocol, projections, pattern in spy_rejections:
        rejected = temp / "RejectedSpy.swift"
        sentinel = "sentinel: preserve generated output\n"
        rejected.write_text(sentinel)
        run("spy-reject-" + label, generate(tool, input_path, rejected, protocol, projections, spy=True),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == sentinel

    forwarding_ambiguity = temp / "ForwardingAmbiguity.swift"
    forwarding_ambiguity.write_text(
        "public protocol ForwardingAmbiguity: Sendable {\n"
        "    func sample(_ values: Int...) -> String\n"
        "    func sample(_ values: String...) -> String\n"
        "}\n"
    )
    actor_forwarding = temp / "IsolatedForwarding.swift"
    actor_forwarding.write_text(
        "@MainActor public protocol IsolatedForwarding {\n"
        "    func sample(_ values: Int...) -> String\n"
        "}\n"
    )
    forwarding_rejections = (
        ("nonvariadic", source, "UserRepository", ("greeting(for:)",), "requires a variadic instance method"),
        ("nonvariadic-subscript", subscript_source, "SubscriptDirectory", ("get_subscript(slot:)",),
         "requires a variadic instance method or subscript accessor"),
        ("unknown", variadic_source, "VariadicDirectory", ("missing(_:)",), "Unknown variadic forwarding selector"),
        ("duplicate", variadic_source, "VariadicDirectory", ("sample(_:)",) * 2,
         "Duplicate variadic forwarding selector"),
        ("actor", actor_forwarding, "IsolatedForwarding", ("sample(_:)",), "adapters require a Sendable protocol"),
        ("ambiguous", forwarding_ambiguity, "ForwardingAmbiguity", ("sample(_:)",),
         "Ambiguous variadic forwarding selector"),
    )
    for label, input_path, protocol, selectors, pattern in forwarding_rejections:
        rejected = temp / "RejectedForwarding.swift"
        previous = "sentinel: preserve the previous forwarding generation\n"
        rejected.write_text(previous)
        run("forwarding-reject-" + label, generate(
            tool, input_path, rejected, protocol, forwarding=selectors),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == previous
    selected_forward = "schema1|ConsumerDomain.ForwardingAmbiguity|sample(_:Int...)->String|Sendable"
    disambiguated_forward = temp / "DisambiguatedForwarding.swift"
    run("forwarding-canonical-selector", generate(
        tool, forwarding_ambiguity, disambiguated_forward, "ForwardingAmbiguity",
        forwarding=(selected_forward,)))
    assert "@escaping @Sendable ([Int]) -> String" in disambiguated_forward.read_text()
    assert "@escaping @Sendable ([String]) -> String" not in disambiguated_forward.read_text()
    expected_rejections = {
        "FixedSelfDirectory": r"Self is fixed to final class 'ConsumerDomain\.FixedDirectory'",
        "AvailabilityDeprecatedRequirement": availability_syntax,
        "AvailabilityMultiplePlatforms": availability_syntax,
        "AvailabilityUnresolvedReceipt": r"Use an unconditional public, nongeneric struct declared in this module",
        "DescriptorCollision": r"Overloads that differ only by effects or result type",
        "UnsupportedEffect": r"Rethrows requires a callback-derived error",
        "EffectfulSetter": r"Effectful getters require read-only properties",
        "GenericSubscript": r"Generic subscripts require explicit specialization",
        "GenericSubscriptSetter": r"Generic specialization requires a synchronous read-only",
        "GenericSubscriptNestedResult": r"Generic subscript results must be concrete or exactly the generic index type",
        "StaticSubscript": r"Type-level subscript scopes require a concrete synchronous Sendable static subscript",
        "GenericStaticSubscript": r"Type-level subscript scopes require a concrete synchronous Sendable static subscript",
        "EffectfulSubscriptSetter": r"Effectful subscript getters require read-only subscripts",
        "BorrowingSubscript": r"Subscript indices require.*without ownership",
        "VariadicSubscript": r"Type-level subscript scopes require a concrete synchronous Sendable static subscript",
        "VariadicSubscriptDescriptorCollision": r"Variadic overloads with identical lowered matcher signatures",
        "VariadicDescriptorCollision": r"Variadic overloads with identical lowered matcher signatures",
        "SubscriptDescriptorCollision": r"methods that collide with accessor descriptors",
    }
    for rejection in sorted((ROOT / "Fixtures/GeneratorRejections").glob("*.swift")):
        output = temp / "Rejected.swift"
        output.write_text("sentinel: preserve the previous generation\n")
        rejection_patterns = [r"BPM001", r":\d+:\d+: error:"]
        if rejection.stem in expected_rejections:
            rejection_patterns.append(expected_rejections[rejection.stem])
        run("reject-" + rejection.stem, generate(tool, rejection, output, rejection.stem),
            fails=True, patterns=rejection_patterns)
        assert output.read_text() == "sentinel: preserve the previous generation\n"
    inheritance_rejections = ROOT / "Fixtures/InheritanceRejections"
    inherited_negatives = [
        ("missing", "MissingParent", (),
         [r"MissingParent\.swift:1:\d+: error: BPM001: .*ConsumerDomain\.UnsuppliedParent"]),
        ("other-module-decoy", "MissingParent", (("DecoyDomain", "DecoyParent"),),
         [r"BPM001: .*ConsumerDomain\.UnsuppliedParent"]),
        ("ambiguous", "MissingParent", (("ConsumerDomain", "DecoyParent"), ("ConsumerDomain", "AmbiguousParent")),
         [r"BPM001: Ambiguous inherited protocol ConsumerDomain\.UnsuppliedParent",
          r"DecoyParent\.swift:1:1", r"AmbiguousParent\.swift:1:1"]),
        ("unqualified-foreign-result", "ForeignQualifiedParent", (("DecoyDomain", "DecoyParent"),),
         [r"DecoyParent\.swift:2:\d+: error: BPM001: Cross-module inherited results require an explicit Swift"]),
        ("cycle", "InheritanceCycleA", (("ConsumerDomain", "InheritanceCycleB"),),
         [r"BPM001: Protocol inheritance cycle: InheritanceCycleA -> InheritanceCycleB -> InheritanceCycleA"]),
        ("result-collision", "InheritedDescriptorCollision", (
            ("ConsumerDomain", "StringLookupParent"), ("ConsumerDomain", "IntLookupParent")),
         [r"BPM001: Overloads that differ only by effects or result type", r"StringLookupParent\.swift:2:\d+",
          r"IntLookupParent\.swift:2:\d+"]),
        ("effect-collision", "InheritedEffectCollision", (
            ("ConsumerDomain", "PlainAccessParent"), ("ConsumerDomain", "AsyncAccessParent")),
         [r"BPM001: Overloads that differ only by effects or result type", r"PlainAccessParent\.swift:2:\d+",
          r"AsyncAccessParent\.swift:2:\d+"]),
    ]
    for label, selected, inputs, patterns in inherited_negatives:
        output = temp / "RejectedInheritance.swift"
        output.write_text("sentinel: preserve the previous generation\n")
        command = generate(
            tool, inheritance_rejections / (selected + ".swift"), output, selected,
            sources=((module, inheritance_rejections / (name + ".swift")) for module, name in inputs),
        )
        run("reject-inheritance-" + label, command, fails=True, patterns=patterns)
        assert output.read_text() == "sentinel: preserve the previous generation\n"
    qualified_missing = r"BPM001: Missing inherited protocol ParentDomain\.SharedDirectory in the supplied source inputs"
    requires_plain_import = (
        r"BPM001: Foreign inherited protocol 'ParentDomain\.SharedDirectory' "
        r"requires an unconditional plain import ParentDomain"
    )
    qualified_negatives = [
        ("unavailable", "QualifiedParentInput", (),
         [r"QualifiedParentInput\.swift:3:\d+: error:", qualified_missing]),
        ("wrong-module", "QualifiedParentInput", (("DecoyDomain", qualified_parent),), [qualified_missing]),
        ("ambiguous", "QualifiedParentInput",
         (*qualified_parents, ("ParentDomain", inheritance_rejections / "QualifiedDuplicateParent.swift")),
         [r"BPM001: Ambiguous inherited protocol ParentDomain\.SharedDirectory",
          r"ForeignSharedDirectory\.swift:5:1", r"QualifiedDuplicateParent\.swift:1:1"]),
        ("no-import", "QualifiedParentWithoutImport", qualified_parents, [requires_plain_import]),
        ("file-local-import", "QualifiedParentWithoutImport",
         (*qualified_parents, ("ConsumerDomain", inheritance_rejections / "QualifiedParentInput.swift")),
         [requires_plain_import]),
        ("conditional-import", "QualifiedConditionalImport", qualified_parents, [requires_plain_import]),
        ("imported-qualifier-shadow", "QualifiedParentInput",
         (*qualified_parents, ("ParentDomain", inheritance_rejections / "QualifiedModuleShadow.swift")),
         [r"QualifiedParentInput\.swift:3:\d+: error: BPM001: .*shadowed by an imported declaration",
          r"QualifiedModuleShadow\.swift:1:1"]),
        ("selective-import-shadow", "QualifiedSelectiveImport",
         (*qualified_parents, ("QualifierAliases", inheritance_rejections / "QualifiedSelectiveAlias.swift")),
         [r"QualifiedSelectiveImport\.swift:4:\d+: error: BPM001: .*shadowed by a selective import",
          r"QualifiedSelectiveImport\.swift:2:1"]),
        ("member-name-collision", "QualifiedMemberCollision", qualified_parents,
         [r"BPM001: A cross-module inherited requirement needs a distinct member name 'remoteLabel'",
          r"ForeignSharedDirectory\.swift:6:\d+", r"QualifiedMemberCollision\.swift:4:\d+"]),
    ]
    for label, selected, inputs, patterns in qualified_negatives:
        output = temp / "RejectedQualifiedInheritance.swift"
        sentinel = b"sentinel: preserve the previous qualified generation\n"
        output.write_bytes(sentinel)
        run("reject-qualified-inheritance-" + label, generate(
            tool, inheritance_rejections / (selected + ".swift"), output, selected, sources=inputs),
            fails=True, patterns=patterns)
        assert output.read_bytes() == sentinel
    associated_negatives = [
        ("missing", associated_source, associated_parents, (),
         r"Missing explicit binding for associated type 'Element'"),
        ("duplicate", associated_source, associated_parents, ("Element=String", "Element=Swift.String"),
         r"Duplicate explicit bindings for associated type 'Element'"),
        ("conflicting", associated_source, associated_parents, ("Element=String", "Element=Int"),
         r"Conflicting explicit bindings for associated type 'Element'"),
        ("unknown", associated_source, associated_parents, ("Element=String", "Missing=String"),
         r"Unknown associated type 'Missing'"),
        ("unsupported", associated_source, associated_parents, ("Element=Double",),
         r"Unsupported concrete associated type binding for 'Element'"),
        ("constraint", inheritance_rejections / "AssociatedUnsupportedConstraint.swift", (), ("Element=String",),
         r"Concrete associated-type bindings support only an optional Sendable constraint"),
        ("qualified-missing", dependency_associated_source, dependency_associated_parents, (),
         r"Missing explicit binding for associated type 'Element'"),
        ("qualified-conflicting", dependency_associated_source, dependency_associated_parents,
         ("Element=String", "Element=Int"), r"Conflicting explicit bindings for associated type 'Element'"),
        ("imported-nominal", inheritance_rejections / "ImportedAssociatedDirectory.swift",
         tuple(("ParentDomain", inheritance_rejections / name) for name in (
             "ForeignAssociatedDirectory.swift", "ForeignNominalElementBranch.swift",
         )), ("Element=String",),
         r"Cross-module inherited results require an explicit Swift.*or a visible bound associated type"),
        ("nominal-collision", inheritance_rejections / "AssociatedNominalCollision.swift",
         (*associated_parents, ("ConsumerDomain", inheritance_rejections / "NominalElementBranch.swift")),
         ("Element=String",), r"Use a supported result type"),
        ("overload-collision", inheritance_rejections / "AssociatedOverloadCollision.swift", (),
         ("Element=String",),
         r"Concrete associated-type bindings need distinct argument labels for overloaded requirement 'put\(_:\)'"),
    ]
    bound_parent_origin = [r"BoundParent\.swift:2:\d+: error:"]
    associated_origins = {
        "qualified-missing": bound_parent_origin,
        "qualified-conflicting": bound_parent_origin,
        "imported-nominal": [r"ForeignNominalElementBranch\.swift:4:\d+: error:"],
        "nominal-collision": [r"NominalElementBranch\.swift:4:\d+: error:"],
        "overload-collision": [r"AssociatedOverloadCollision\.swift:3:\d+",
                               r"AssociatedOverloadCollision\.swift:4:\d+"],
    }
    for label, selected, inputs, bindings, diagnostic in associated_negatives:
        output = temp / "RejectedAssociatedBinding.swift"
        sentinel = b"sentinel: preserve the previous associated binding generation\n"
        output.write_bytes(sentinel)
        patterns = [r"BPM001: " + diagnostic, *associated_origins.get(label, ())]
        run("reject-associated-binding-" + label, generate(
            tool, selected, output, selected.stem, sources=inputs, associated_bindings=bindings),
            fails=True, patterns=patterns)
        assert output.read_bytes() == sentinel
    parameterized_negatives = [
        ("explicit-conflict", parameterized_parent_source, ("Element=String",), [
            r"IntDirectory\.swift:3:56: error: BPM001: Inherited specialization for 'Element' "
            r"requires Swift\.Int, but the explicit binding is Swift\.String",
        ]),
        ("nested-argument", inheritance_rejections / "NestedPrimaryArgument.swift", (), [
            r"NestedPrimaryArgument\.swift:3:\d+: error: BPM001: Unsupported inherited specialization argument for 'Element'",
        ]),
        ("graph-conflict", inheritance_rejections / "ConflictingPrimaryParents.swift", (), [
            r"ConflictingPrimaryParents\.swift:4:\d+: error: BPM001: Conflicting inherited specializations "
            r"for 'Element' require Swift\.Int at .*ConflictingPrimaryParents\.swift:3:\d+ and Swift\.String",
        ]),
    ]
    for label, selected, bindings, patterns in parameterized_negatives:
        output = temp / "RejectedParameterizedParent.swift"
        sentinel = b"sentinel: preserve prior parameterized parent generation\n"
        output.write_bytes(sentinel)
        run("reject-parameterized-parent-" + label, generate(
            tool, selected, output, selected.stem, sources=dependency_associated_parents, associated_bindings=bindings),
            fails=True, patterns=patterns)
        assert output.read_bytes() == sentinel
    inferred_iterator = inheritance_rejections / "InferredIntCursor.swift"
    iterator_alias_extension = inheritance_rejections / "IteratorAliasExtensionShadow.swift"
    iterator_negatives = [
        ("mismatch", "ConsumerDomain", iterator_mismatch_source, iterator_sources,
         iterator_binding, iterator_mismatch_patterns),
        ("unqualified-alias", "ConsumerDomain", iterator_source, iterator_sources, ("Iterator=IntCursor",),
         [r"BPM001: Dependent iterator binding 'Iterator' requires a module-qualified struct in ConsumerDomain"]),
        ("missing-source", "ConsumerDomain", iterator_source, iterator_sources[:1], iterator_binding,
         [r"BPM001: Cannot resolve 'ConsumerDomain\.IntCursor\.Element' from supplied source"]),
        ("missing-witness", "ConsumerDomain", iterator_source,
         (*iterator_sources[:1], ("ConsumerDomain", inferred_iterator)), ("Iterator=ConsumerDomain.InferredIntCursor",), [
             r"CursorSequence\.swift:3:\d+: error: BPM001: Cannot resolve "
             r"'ConsumerDomain\.InferredIntCursor\.Element' from supplied source",
             r"Declare exactly one unconditional public typealias Element",
         ]),
        ("extension-alias-shadow", "ConsumerDomain", iterator_source,
         (*iterator_sources, ("ConsumerDomain", iterator_alias_extension)), iterator_binding, [
             r"CursorSequence\.swift:3:\d+: error: BPM001: Cannot resolve "
             r"'ConsumerDomain\.IntCursor\.Element' from supplied source\. "
             r"A supplied extension could change Element or Swift lookup\.",
             r"IteratorAliasExtensionShadow\.swift:8:\d+",
         ]),
        ("generated-module-shadow", "Stubs", iterator_source,
         tuple(("Stubs", path) for _, path in iterator_sources), ("Iterator=Stubs.IntCursor",), [
             r"CursorSequence\.swift:3:\d+: error: BPM001: Dependent iterator binding cannot use "
             r"module 'Stubs' because that name is used by the generated mock\.",
         ]),
    ]
    for label, module, selected, inputs, bindings, patterns in iterator_negatives:
        output = temp / "RejectedIteratorBinding.swift"
        sentinel = b"sentinel: preserve prior iterator binding generation\n"
        output.write_bytes(sentinel)
        run("reject-iterator-binding-" + label, generate(
            tool, selected, output, selected.stem, module=module, sources=inputs, associated_bindings=bindings),
            fails=True, patterns=patterns)
        assert output.read_bytes() == sentinel
    mapper_fixture = ROOT / "Fixtures/FailureMappingConsumer"
    mapper_tests = "Tests/FailureMappingProbeTests/FailureMappingTests.swift"
    baseline_probe = (mapper_fixture / "Variants/A/Probe.swift").read_text()
    updated_probe = (mapper_fixture / "Variants/B/Probe.swift").read_text()
    inserted_member = "    func alpha() throws(ProbeFailure) -> String\n"
    assert updated_probe.count(inserted_member) == 1
    assert updated_probe.replace(inserted_member, "", 1) == baseline_probe
    for label in ("A", "B"):
        package = temp / ("failure-mapping-" + label)
        probe = package / "Sources/ProbeDomain/Probe.swift"
        double = package / "Sources/ProbeDoubles/ProbeMock.swift"
        test_code = package / mapper_tests
        for path in (probe, double, test_code):
            path.parent.mkdir(parents=True, exist_ok=True)
        (package / "Package.swift").write_bytes((mapper_fixture / "Package.swift").read_bytes())
        probe.write_bytes((mapper_fixture / "Variants" / label / "Probe.swift").read_bytes())
        test_code.write_bytes((mapper_fixture / mapper_tests).read_bytes())
        run("failure-mapping-generation-" + label, generate(tool, probe, double, "Probe", module="ProbeDomain"))
        assert not re.search(r"failureMapping[0-9]+:", double.read_text())
        run_swift("failure-mapping-consumer-" + label, ["test", "--jobs", "4", "--package-path", package],
                  extra_environment={"BLUEPRINT_FAILURE_MAPPING_FRAMEWORK_PATH": str(ROOT)},
                  patterns=[r"GEN007_namedFailureMappingKeepsTheOriginalEndpointAcrossRegeneration\(\) passed",
                            r"GEN007_failureMappingsSelectOverloadsByArgumentType\(\) passed"])
    run_swift("runtime-tests", ["test"], patterns=[
        r"\b[1-9]\d* tests?\b.*\bpassed\b",
        r"DX027_traceDistinguishesPrunedHistoryFromTheExportWindow\(\) passed",
        r"DX027_archivedTracePreservesOriginalEpochAndGaps\(\) passed",
        r"DX027_traceMergesCancellationRequestsWithTerminalRowsAndKeepsSeparatePruning\(\) passed",
        r"DX027_traceBoundsEscapedEndpointTextWithoutVisitingPayloads\(\) passed",
        r"DX027_checkedVerificationBoundsTheFailureWithoutDescribingPayloads\(\) passed",
        r"DX027_mainActorVerificationUsesTheSameBoundedRenderer\(\) passed",
        r"DX027_renderingPreservesSmallAndExactlyBudgetedCountFailures\(\) passed",
        r"RUN017_registryResolvesExactTypedFactoriesAndKeepsPublishedCopiesIndependent\(\) passed",
        r"RUN017_registryRejectsCyclesAndDepthBeforeEnteringTheRepeatedFactory\(\) passed",
        r"RUN024_delayedSequenceResumesAtExactManualDeadline\(\) passed",
        r"RUN024_delayedSequenceCancellationKeepsDetachedAdmissionAndConsumesStep\(\) passed",
        r"RUN024_delayedSequenceContinuousClockWakesInvocation\(\) passed",
        r"RUN013_reboundDetachedTaskUsesEntireChainAndRestoresContext\(\) passed",
        r"RUN013_explicitHandleRefusesOtherSessionsAndEndpointInstances\(\) passed",
        r"RUN013_rebindDoesNotExtendOriginatingScopeLifetime\(\) passed",
        r"RUN013_explicitHandlesValidateEpochAndSessionFinish\(\) passed",
        r"RUN013_transportHandleRetainsNoPlanPayload\(\) passed",
        r"RUN013_nestedScopesRestoreAndConsultOuterRulesOnMiss\(\) passed",
        r"RUN013_anExhaustedInnerWinnerBlocksOuterBaseAndForwarding\(\) passed",
        r"RUN013_lexicalScopesAreBoundToTheEndpointInstanceAndTaskContext\(\) passed",
        r"RUN013_scopeRestoresAfterErrorAndTaskCancellation\(\) passed",
        r"RUN013_closedAndResetScopesRejectWithoutAdmitting\(\) passed",
        r"RUN013_admittedMatchingKeepsPinnedOverlayAcrossDetachedReset\(\) passed",
        r"RUN013_asyncRulePriorityBeatsRegistrationAndUsesLatestForTies\(\) passed",
        r"RUN013_asyncScopeLayerWinsBeforeRulePriorityAndExhaustion\(\) passed",
        r"RUN027_competingOrderedSelectionsCommitTogetherOrLeaveEveryIDUnclaimed\(\) passed",
        r"RUN027_orderedClaimsCannotProveAnEarliestMatchAfterPruning\(\) passed",
        r"RUN007_namedSendableMatchersDescribeCompositionWithoutPrintingValues\(\) passed",
        r"RUN007_namedMainActorMatchersDescribeActorLocalPredicates\(\) passed",
    ])
    run_swift("consumer-tests", ["test", "--package-path", "Fixtures/ProtocolConsumer"],
        patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b",
                  r"RUN027_RUN029_orderedConsumptionHonorsClaimedBarriersAndKeepsHistory\(\) passed",
                  r"RUN017_checkedEndpointUsesRegisteredDomainDefaultAfterStubAndForwarding\(\) passed",
                  r"RUN015_generatedScenarioReservesOnceAndIgnoresStaleCompletionAfterABA\(\) passed",
                  r"RUN015_generatedScenarioPublishesCurrentSuccessfulCompletion\(\) passed",
                  r"RUN015_liveOverlayCompletionSurvivesBaseOnlyReplacement\(\) passed",
                  r"RUN015_closedOverlayRejectsPendingCompletionOnItsPinnedScenario\(\) passed",
                  r"RUN015_detachedCompletionAndReusablePlanPreserveIndependentCursors\(\) passed",
                  r"RUN024_generatedDelayedSequenceKeepsTypedCancellationBeforeRegistration\(\) passed",
                  r"GEN040_explicitByteBufferAdapterCopiesOnlyTheBoundedPrefix\(\) passed",
                  r"GEN021_generatedPackProviderPreservesTypedArgumentsAndIdentity\(\) passed",
                  r"GEN034_generatedSendingWitnessTransfersBothDirectionsAndRetainsOnlySnapshots\(\) passed",
                  r"GEN033_generatedFactoryYieldsIndependentlyOwnedResults\(\) passed",
                  r"GEN032_generatedConsumingInputProjectsBorrowAndDestroysOnce\(\) passed",
                  r"GEN036_generatedIsolatedAnswerRunsOnOriginalActorAndVerifiesIdentity\(\) passed",
                  r"DX027_generatedSessionExportsAnExplicitMetadataOnlyTrace\(\) passed",
                  r"DX027_nativeReporterReceivesABoundedVerificationMessage\(\) passed",
                  r"GEN009_fluentSelfUsesTypedFactoryAndVerifiesOnInvokedMock\(\) passed",
                  r"GEN018_lazyAutoclosureEvaluatesOnlyOnExplicitAnswerRequests\(\) passed",
                  r"GEN018_materializedMatcherAndAnswerReuseOneValue\(\) passed",
                  r"GEN018_finishedMaterializedEndpointDoesNotEvaluate\(\) passed",
                  r"RUN013_consumerRebindsDetachedServiceCallsAndRejectsStaleHandle\(\) passed",
                  r"RUN013_publicScopedRulesFollowProtocolCallsAndUnwind\(\) passed",
                  r"RUN013_generatedAsyncRulePriorityComposesWithWinningCaptures\(\) passed",
                  r"RUN013_generatedScopedRulesFollowProtocolCallsAndUnwind\(\) passed",
                  r"RUN013_generatedScopePreservesTheCallersActor\(\) passed",
                  r"RUN007_generatedVerificationReportsOnlyExplicitMatcherDescriptions\(\) passed",
                  r"RUN007_generatedSendableTupleVerificationReportsSourceLabels\(\) passed",
                  r"RUN007_generatedMainActorTupleVerificationReportsSourceLabels\(\) passed",
                  r"RUN034_detachedMatchingCannotConsumeCurrentSequencePosition\(\) passed",
                  r"RUN034_detachedSequenceRestartKeepsOldReservationSeparate\(\) passed",
                  r"RUN034_quiescentSequenceRestartRewindsExhaustedRules\(\) passed",
                  r"GEN007_typedAsyncDescriptorSetupAndVerificationDoNotInvokeWitness\(\) passed",
                  r"RUN009_generatedWinningRulesCaptureOnceThroughReentryAndConcurrency\(\) passed",
                  r"SYS007_concurrentGeneratedCallsKeepUniqueSessionInvocationIDs\(\) passed",
                  r"SYS005_checkoutServiceUsesLiveDependencyAdapters\(\) passed",
                  r"SYS005_generatedAdapterMocksOnlyRecordCallsThroughProtocols\(\) passed",
                  r"GEN002_diamondBranchesShareOneTypedWitnessAndEndpoint\(\) passed",
                  r"GEN002_unstubbedSharedWitnessReportsItsOriginalDeclarationFile\(\) passed",
                  r"GEN002_qualifiedParentsKeepModuleIdentityAndForeignDeclarationProvenance\(\) passed",
                  r"GEN008_concretePrimaryAssociatedTypeBindingSurvivesConsumerCalls\(\) passed",
                  r"GEN008_inheritedAssociatedRequirementKeepsItsDeclarationSource\(\) passed",
                  r"GEN008_qualifiedParentBindsAssociatedTypeAcrossTargets\(\) passed",
                  r"GEN008_parameterizedParentInfersConcreteWitnessAcrossTargets\(\) passed",
                  r"GEN008_iteratorEqualitySurvivesInheritedPrimaryNormalization\(\) passed",
                  r"GEN004B_protocolBaselineRemainsAvailableAtPackageFloor\(\) passed",
                  r"GEN004B_guardedMockKeepsReceiptStorageAndSurfacesAvailable\(\) passed",
                  r"BLUEPRINT_AVAILABILITY_GUARDED_RECEIPT Swift\.Int 47",
                  r"RUN011_generatedOrdinaryMockInvokesCallbackWithinWitness\(\) passed",
                  r"GEN019_generatedOrdinaryInoutWitnessWritesBackBeforeReturnAndThrow\(\) passed",
                  r"GEN010_genericMethodSeparatesIntAndStringSpecializations\(\) passed",
                  r"GEN011_polymorphicProviderKeepsUnseenValuesTypedAndRecordsSessionMetadata\(\) passed",
                  r"GEN015_RUN005_generatedRethrowsProviderPreservesNonescapingCallbackAndError\(\) passed",
                  r"GEN015_RUN005_constantRethrowsProviderCanSkipCallerCallback\(\) passed",
                  r"GEN015_RUN005_generatedRethrowsPairPreservesEitherCallbackError\(\) passed",
                  r"GEN015_RUN005_generatedAsyncRethrowsKeepsSuspendedCallAndOriginalError\(\) passed",
                  r"GEN015_RUN005_mixedRethrowsPreservesOrdinaryArgumentsAndBothErrors\(\) passed",
                  r"GEN015_RUN005_mixedAsyncRethrowsPreservesOrdinaryArgumentsAndError\(\) passed",
                  r"RUN010_oneShotCaptureRejectsDuplicateWhileAcquiredAndFinishes\(\) passed",
                  r"RUN010_oneShotCancellationRetiresOnlyItsPendingCapture\(\) passed",
                  r"RUN010_oneShotCaptureResetInvalidatesEarlierEpoch\(\) passed",
                  r"RUN010_scheduledOneShotCompetesWithDirectDeliveryAtDeadline\(\) passed",
                  r"RUN010_scheduledOneShotKeepsAcquiredCallbackThroughFinish\(\) passed",
                  r"RUN010_scheduledOneShotAcquiresEarliestOfTwoDueContenders\(\) passed",
                  r"RUN010_cancellingScheduledOneShotAttemptLeavesCaptureAvailable\(\) passed",
                  r"RUN010_scheduledOneShotResetAndFinishRejectQueuedDeliveries\(\) passed",
                  r"RUN010_scheduledOneShotRejectsNegativeDelayWithoutClaimingOnEitherClock\(\) passed",
                  r"RUN010_continuousOneShotZeroDelayAndDirectInvocationShareOneClaim\(\) passed",
                  r"RUN010_continuousOneShotTimerHonorsDeadlineAndFinishesAcquiredDelivery\(\) passed",
                  r"RUN010_continuousOneShotPendingAttemptsRespectCancelDirectWinAndTeardown\(\) passed",
                  r"RUN010_droppingManualSessionRejectsPendingScheduledOneShot\(\) passed",
                  r"GEN012_returnOnlyOverloadsUseSeparateTypedEndpoints\(\) passed",
                  r"RUN025_cancellationRequestKeepsGeneratedAnswerActiveUntilReturn\(\) passed",
                  r"RUN025_detachedCancellationRequestStaysWithTypedThrowingAdmission\(\) passed",
                  r"RUN016_generatedSubscriptStorageKeepsConcurrentKeysAndAccessorHistories\(\) passed",
                  r"RUN016_reentrantHashAndEqualityRetryWithoutLosingIndexedUpdates\(\) passed",
                  r"RUN016_replacedSubscriptPayloadReentersAfterCommit\(\) passed",
                  r"GEN016_escapingCallbackCapturesOnlyTheLatestWinningRule\(\) passed",
                  r"GEN016_escapingCallbackLifetimeFollowsCaptureSelectionAndSessionEpoch\(\) passed",
                  r"GEN016_actorEscapingCallbackReplaysOnMainActorAfterDetachedRegistration\(\) passed",
                  r"GEN016_actorEscapingCallbackReleasesPayloadAcrossResetAndFinish\(\) passed",
                  r"GEN016_throwingEscapingCallbackPreservesItsDeclaredFailureDuringReplay\(\) passed",
                  r"GEN016_throwingEscapingCallbackRetiresCapturesOnResetAndFinish\(\) passed",
                  r"GEN016_asyncEscapingCallbackReplaySurvivesResetAfterAcquisition\(\) passed",
                  r"GEN016_asyncEscapingCallbackReplaySurvivesFinishAfterAcquisition\(\) passed",
                  r"GEN016_asyncThrowingEscapingCallbackReturnsAcrossResetAfterAcquisition\(\) passed",
                  r"GEN016_asyncThrowingEscapingCallbackThrowsItsDeclaredErrorAcrossFinish\(\) passed",
                  r"GEN016_mainActorAsyncEscapingCallbackReplaySurvivesResetAfterAcquisition\(\) passed",
                  r"GEN016_mainActorAsyncEscapingCallbackReplaySurvivesFinishAfterAcquisition\(\) passed",
                  r"GEN016_mainActorThrowingEscapingCallbackPreservesActorAndDeclaredError\(\) passed",
                  r"GEN016_mainActorThrowingEscapingCallbackRetiresPayloadOnResetAndFinish\(\) passed",
                  r"GEN016_mainActorAsyncThrowingEscapingCallbackReturnsAcrossResetAfterAcquisition\(\) passed",
                  r"GEN016_mainActorAsyncThrowingEscapingCallbackThrowsItsDeclaredErrorAcrossFinish\(\) passed",
                  r"GEN016_scheduledCallbackDeliversAtExactManualDeadlineOnce\(\) passed",
                  r"GEN016_scheduledCallbackResetRetiresPendingDelivery\(\) passed",
                  r"GEN016_scheduledCallbackFinishRetiresPendingDelivery\(\) passed",
                  r"GEN016_scheduledCallbackRejectsInvalidClockAndDelay\(\) passed",
                  r"GEN016_scheduledCallbacksAcquiredTogetherFinishAfterReentrantReset\(\) passed",
                  r"GEN016_scheduledCallbackCancellationRetiresExactQueuedReceipt\(\) passed",
                  r"GEN016_scheduledCallbackCancellationCannotChangeAnAcquiredDelivery\(\) passed",
                  r"GEN016_scheduledCallbackCancellationRejectsFinishedReceipt\(\) passed",
                  r"GEN016_scheduledCallbackCancellationKeepsSessionsIndependent\(\) passed",
                  r"GEN016_scheduledCallbackCancellationKeepsEpochsIndependent\(\) passed",
                  r"GEN016_repeatingScheduledCallbackPreservesSuppliedOrderAndExactDeadlines\(\) passed",
                  r"GEN016_repeatingScheduledCallbackCancellationKeepsAcquiredSiblings\(\) passed",
                  r"GEN016_repeatingScheduledCallbackRejectsInvalidOffsetsAtomically\(\) passed",
                  r"GEN016_repeatingScheduledCallbackResetRetiresFutureOnly\(\) passed",
                  r"GEN016_repeatingScheduledCallbackFinishRetiresFutureOnly\(\) passed",
                  r"GEN016_continuousScheduledCallbackRespectsMonotonicDeadlineAcrossFinish\(\) passed",
                  r"GEN016_continuousScheduledCallbackCancellationStaysRetired\(\) passed",
                  r"GEN016_continuousScheduledCallbackResetRetiresFarFutureDelivery\(\) passed",
                  r"GEN016_continuousScheduledCallbackFinishRetiresFarFutureDelivery\(\) passed",
                  r"GEN016_continuousScheduledCallbackDoesNotKeepSessionAlive\(\) passed",
                  r"GEN016_continuousRepeatingScheduledCallbackUsesDeadlineAndSuppliedTieOrder\(\) passed",
                  r"GEN016_continuousRepeatingScheduledCallbackCancelsQueuedTiesFromFirstReplay\(\) passed",
                  r"GEN016_continuousRepeatingScheduledCallbackResetRetiresQueuedTies\(\) passed",
                  r"GEN016_continuousRepeatingScheduledCallbackFinishRetiresQueuedTies\(\) passed",
                  r"GEN016_continuousRepeatingScheduledCallbackDeallocationRetiresEveryReceipt\(\) passed"])
    run_swift("consumer-demo", ["run", "--package-path", "Fixtures/ProtocolConsumer", "consumer-demo"],
        patterns=[r"PASS: generated protocol"])
    run_swift("typed-throwing-callback-consumer-demo", [
        "run", "--package-path", "Fixtures/ProtocolConsumer", "consumer-demo", "--typed-throwing-callback"],
        patterns=[r"PASS: GEN016 executable replayed a typed callback success and failure",
                  r"PASS: GEN016 executable replayed an async typed callback success and failure",
                  r"PASS: GEN016 executable replayed a MainActor typed callback success and failure",
                  r"PASS: GEN016 executable replayed a MainActor async typed callback success and failure"])
    modules = Path(run_swift("consumer-bin-path", [
        "build", "--package-path", "Fixtures/ProtocolConsumer", "--show-bin-path"]).strip())
    run("imported-interface-native-consumer", [
        sys.executable, "scripts/verify_imported_interface.py", "--tool", tool, "--swiftc", swiftc,
        "--sdk", sdk, "--sdk-version", sdk_version, "--runtime-modules", modules,
        "--runtime-library", modules / "BlueprintMocking.o", "--evidence-dir", EVIDENCE / "imported-interface",
    ], env=swift_environment, timeout=180, patterns=[
        r"PASS: GEN003 run-independent-binary-consumer",
        r"PASS: GEN003 reject-wrong-module",
        r"PASS: GEN003 reject-wrong-target",
    ])
    run_swift("subclass-swiftpm-consumer", [
        "run", "--package-path", "Fixtures/ProtocolConsumer", "SubclassBootstrapProbe"],
        patterns=[r"PASS: initializer reentry reached the override"])
    run("subclass-native-bootstrap", [
        sys.executable, "scripts/verify_subclass_bootstrap.py", "--tool", tool, "--swiftc", swiftc,
        "--sdk", sdk, "--runtime-build", modules, "--evidence-dir", EVIDENCE / "subclass-bootstrap"],
        env=swift_environment, patterns=[r"PASS: cross-module MainActor subclass bootstrap"])
    built_subclass = ROOT / "Fixtures/ProtocolConsumer/Sources/SubclassBootstrapProbe/BootstrapRendererMock.swift"
    regenerated_subclass = EVIDENCE / "subclass-bootstrap/BootstrapRendererMock.swift"
    if built_subclass.read_bytes() != regenerated_subclass.read_bytes():
        raise ValueError("The committed SwiftPM subclass fixture differs from standalone generation")
    run("typed-throwing-callback-deployment-floor", ["xcrun", "vtool", "-show-build", modules / "consumer-demo"],
        env=swift_environment, patterns=[r"platform MACOS", r"minos 13\.0\b"])
    compiler_floor = [
        swiftc, "-swift-version", "6", "-target",
        f"{platform.machine()}-apple-macos{deployment_target}", "-sdk", sdk,
    ]
    run("availability-generated-macos-floor", [
        *compiler_floor, "-typecheck", "-module-name", "ConsumerDoubles", "-I", modules, availability_generated,
    ], env=swift_environment)
    member_only_mock = temp / "AvailabilityMemberOnlyMock.swift"
    receipt_witness = "    public func receipt() -> NewReceipt {"
    assert availability_mock.count(receipt_witness) == 1
    available_annotation = availability_gate.group(0)
    unguarded_mock_storage = availability_mock.replace(available_annotation, "", 1).replace(
        receipt_witness, "    " + available_annotation + receipt_witness, 1,
    )
    member_only_mock.write_text(unguarded_mock_storage)
    storage_line, = [
        number for number, line in enumerate(unguarded_mock_storage.splitlines(), 1)
        if re.fullmatch(r"    private let __endpoint\d+: SyncEndpoint<Void, NewReceipt>", line)
    ]
    run("compile-reject-availability-member-only-storage", [
        *compiler_floor, "-typecheck", "-module-name", "ConsumerDoubles", "-I", modules, member_only_mock,
    ], env=swift_environment, fails=True, patterns=[
        rf"AvailabilityMemberOnlyMock\.swift:{storage_line}:\d+: error: "
        r"'NewReceipt' is only available in macOS 14\.0 or newer",
    ])
    unavailable_mock = r"'AvailabilityDirectoryMock' is only available in macOS 14\.0 or newer"
    disjoint_inout = ROOT / "Fixtures/CompileSuccesses/OrdinaryInoutDisjointAccess.swift"
    for suffix, flags in (("", []), ("-DefaultIsolation", ["-default-isolation", "MainActor"])):
        run("compile-accept-OrdinaryInoutDisjointAccess" + suffix,
            [*compiler_floor, "-emit-sil", "-o", os.devnull, "-I", modules, *flags, disjoint_inout],
            env=swift_environment)

    patterns = {
        "AvailabilityUnguardedWitness": r"'receipt\(\)' is only available in macOS 14\.0 or newer",
        "AvailabilityUnguardedMock": (
            rf"(?s)(?=.*AvailabilityUnguardedMock\.swift:5:\d+: error: {unavailable_mock})"
            rf"(?=.*AvailabilityUnguardedMock\.swift:8:\d+: error: {unavailable_mock})"
        ),
        "AvailabilityUnguardedHelpers": (
            rf"(?s)(?=.*AvailabilityUnguardedHelpers\.swift:3:\d+: error: {unavailable_mock})"
            rf"(?=.*AvailabilityUnguardedHelpers\.swift:7:\d+: error: {unavailable_mock})"
        ),
        "MainActorAssertionAccess": r"main actor-isolated.*'wasCalled",
        "MainActorAsyncTransport": r"sending 'entry' risks causing data races",
        "MainActorSpyAsyncTransport": r"sending 'entry' risks causing data races",
        "MainActorSpyWitnessAccess": r"main actor-isolated.*'display",
        "MainActorStubbingAccess": r"main actor-isolated.*'display",
        "MainActorVerificationAccess": r"main actor-isolated.*'display",
        "MainActorWitnessAccess": r"main actor-isolated.*'display",
        "OwnedResultCapturedReplay": r"noncopyable 'previous' cannot be consumed when captured by an escaping closure",
        "OwnedResultErasure": r"return expression of type 'FreshOwnedTicket' does not conform to 'Copyable'",
        "OwnedResultFixedReturn": r"has no member 'willReturn'",
        "ByteBufferDeferredAddressCapture": r"capture of 'buffer' with non-Sendable type 'UnsafeBufferPointer<UInt8>'",
        "PackProviderFixedArity": r"type 'FixedArityPackProvider' does not conform to protocol 'PackProviderDirectoryMockBehavior'",
        "PackProviderWrongResultShape": r"type 'WrongResultPackProvider' does not conform to protocol 'PackProviderDirectoryMockBehavior'",
        "SendingRetainedInput": r"sending 'input' risks causing data races",
        "SendingUseAfterTransfer": r"sending 'packet' risks causing data races",
        "SendingRetainedResult": r"sending 'result' risks causing data races",
        "SendingFixedResult": r"capture of 'packet' with non-Sendable type 'SendingPacket'",
        "ConsumingInputUseAfterConsume": r"'ticket' used after consume",
        "ConsumingInputDuplicateTransfer": r"'ticket' consumed more than once",
        "ConsumingInputEscapedBorrow": r"'ticket' cannot be captured by an escaping closure since it is a borrowed parameter",
        "IsolatedActorErasedAnswer": r"cannot convert return expression of type.*isolated IsolatedDirectoryWorker",
        "IsolatedActorMatcherAccess": r"actor-isolated property 'count' can not be referenced from a Sendable closure",
        "IsolatedActorMissingAwait": r"actor-isolated instance method 'sample' cannot be called from outside of the actor",
        "FluentSelfWrongResult": (
            r"cannot convert value of type 'OtherDirectory' to expected argument type 'FluentDirectoryMock'"
        ),
        "FluentSelfExistentialInput": r"member 'accepts' cannot be used on value of type 'any SelfOperand'",
        "WrongResult": r"cannot convert value of type 'Int'",
        "ReturnOnlyOverloadWrongResult": (
            r"ReturnOnlyOverloadWrongResult\.swift:\d+:\d+: error: "
            r"cannot convert value of type 'String' to expected argument type 'Int'"
        ),
        "AssociatedBindingWrongResult": r"cannot convert value of type 'Int' to expected argument type 'String'",
        "WrongError": r"cannot convert value of type 'Other'",
        "GeneratedWrongError": r"cannot convert value of type 'UnrelatedError'",
        "GeneratedOrdinalFailureMapping": r"incorrect argument label.*failureMapping0.*failureMappings",
        "GeneratedWrongFailureMappingResult": r"'WrongFailureMappingError'.*'RepositoryError'",
        "AsyncAnswerForSync": r"cannot pass function of type.*async",
        "InvalidSendablePayload": r"type 'DirectoryEntry' does not conform to the 'Sendable' protocol",
        "NonSendableCapture": r"capture of 'box'.*non-[Ss]endable",
        "SchemaMismatch": r"cannot find type 'BlueprintRuntimeSchemaV999'",
        "ThrowForSync": r"has no member 'willThrow'",
        "ThrowForAsync": r"has no member 'willThrow'",
        "ThrowingAnswerForAsync": r"to non-throwing function type",
        "ThrowForNever": r"has no member 'willThrow'",
        "TypeSubscriptWrongNewValue": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "ValueForNever": r"cannot convert value of type 'String'.*'Never'",
        "AsyncAnswerForSyncThrowing": r"to parameter expecting synchronous function type",
        "GenericMethodWrongConstraint": r"requires that 'UnhashableGenericMethodValue' conform to 'Hashable'",
        "GenericMethodWrongMatcher": r"cannot convert value of type 'Matcher<String>' to expected argument type 'Matcher<Int>'",
        "GenericProviderExtraConstraint": r"type 'OverconstrainedIdentityProvider' does not conform to protocol 'GenericProviderDirectoryMockBehavior'",
        "DeferredAutoclosure": r"passing non-escaping parameter",
        "MaterializedAutoclosureAsyncMatcher": r"cannot pass function of type.*async.*expecting synchronous function type",
        "MaterializedAutoclosureThrowingMatcher": r"invalid conversion from throwing function of type.*non-throwing function type",
        "GeneratedRuleScopeWrongSelector": r"cannot convert value of type 'Int.Type' to expected argument type 'String.Type'",
        "RethrowingProviderUnrelatedThrow": r"may only throw if its parameter does",
        "RethrowingProviderNoThrowsStub": r"'RethrowingDirectoryMock.Stubs' has no member 'apply'",
        "RethrowingPairMissingTry": r"call can throw, but it is not marked with 'try'",
        "AsyncRethrowingMissingTry": r"call can throw, but it is not marked with 'try'",
        "AsyncRethrowingProviderUnrelatedThrow": r"may only throw if its parameter does",
        "AsyncRethrowingNonSendableCapture": r"capture of 'payload' with non-[sS]endable type 'NonSendableAsyncRethrowingPayload'",
        "GenericSubscriptWrongConstraint": r"requires that 'UnhashableKey' conform to 'Hashable'",
        "GenericSubscriptWrongMatcher": r"cannot convert value of type 'Matcher<String>' to expected argument type 'Matcher<Int>'",
        "GenericSubscriptUnsupportedSpecialization": r"no exact matches in call to instance method 'get_subscript'",
        "GenericSubscriptWrongResult": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "EscapingCallbackMainActorConversion": (
            r"EscapingCallbackMainActorConversion\.swift:\d+:\d+: error: .*loses global actor 'MainActor'"
        ),
        "EscapingCallbackNonSendableCapture": (
            r"EscapingCallbackNonSendableCapture\.swift:\d+:\d+: error: "
            r"capture of 'payload'.*non-[Ss]endable type 'NonSendableCallbackPayload'"
        ),
        "EscapingCallbackWrongReplayInput": (
            r"EscapingCallbackWrongReplayInput\.swift:\d+:\d+: error: "
            r"cannot convert value of type 'String' to expected argument type 'Int'"
        ),
        "MainActorEscapingCallbackNonisolatedReplay": (
            r"MainActorEscapingCallbackNonisolatedReplay\.swift:\d+:\d+: error: "
            r"call to main actor-isolated.*'invoke'.*synchronous nonisolated context"
        ),
        "ThrowingEscapingCallbackWrongError": (
            r"ThrowingEscapingCallbackWrongError\.swift:\d+:\d+: error: invalid conversion of thrown error type "
            r"'OtherEscapingCallbackError' to 'CallbackFixtureError'"
        ),
        "ThrowingEscapingCallbackEffects": (
            r"ThrowingEscapingCallbackEffects\.swift:8:\d+: error: call can throw, but it is not marked with 'try'"
        ),
        "AsyncEscapingCallbackSynchronousReplay": (
            r"AsyncEscapingCallbackSynchronousReplay\.swift:\d+:\d+: error: "
            r"'async' call in a function that does not support concurrency"
        ),
        "AsyncThrowingEscapingCallbackWrongError": (
            r"AsyncThrowingEscapingCallbackWrongError\.swift:\d+:\d+: error: invalid conversion of thrown error type "
            r"'ForeignAsyncCallbackError' to 'AsyncCallbackFixtureError'"
        ),
        "MainActorAsyncEscapingCallbackNonisolatedReplay": (
            r"MainActorAsyncEscapingCallbackNonisolatedReplay\.swift:\d+:\d+: error: "
            r"cannot convert value actor-isolated to 'MainActor' to specified type actor-isolated to 'ReplayFixtureActor'"
        ),
        "MainActorThrowingEscapingCallbackWrongError": (
            r"MainActorThrowingEscapingCallbackWrongError\.swift:\d+:\d+: error: "
            r"invalid conversion of thrown error type 'ForeignMainActorCallbackError' to 'MainActorCallbackFixtureError'"
        ),
        "MainActorThrowingEscapingCallbackNonisolatedReplay": (
            r"MainActorThrowingEscapingCallbackNonisolatedReplay\.swift:\d+:\d+: error: "
            r"call to main actor-isolated.*'invoke\(_:onUnavailable:\)'.*synchronous nonisolated context"
        ),
        "MainActorAsyncThrowingEscapingCallbackWrongError": (
            r"MainActorAsyncThrowingEscapingCallbackWrongError\.swift:\d+:\d+: error: "
            r"invalid conversion of thrown error type 'ForeignMainActorAsyncCallbackError' to 'MainActorAsyncCallbackFixtureError'"
        ),
        "MainActorAsyncThrowingEscapingCallbackNonisolatedReplay": (
            r"MainActorAsyncThrowingEscapingCallbackNonisolatedReplay\.swift:\d+:\d+: error: "
            r"cannot convert value actor-isolated to 'MainActor' to specified type actor-isolated to 'ThrowingReplayFixtureActor'"
        ),
        "CallbackSpyDeferredCapture": r"passing non-escaping parameter 'callback'.*'@escaping'",
        "ImmediateCallbackDeferredCapture": (
            r"ImmediateCallbackDeferredCapture\.swift:\d+:\d+: error: "
            r"passing non-escaping parameter 'callback'.*'@escaping'"
        ),
        "CallbackSpyDetachedCapture": r"escaping closure captures non-escaping value",
        "InoutSpyRetainsAccess": r"escaping closure captures 'inout' parameter 'value'",
        "OrdinaryInoutRetainsAccess": (
            r"OrdinaryInoutRetainsAccess\.swift:\d+:\d+: error: escaping closure captures 'inout' parameter 'value'"
        ),
        "OrdinaryInoutOverlappingAccess": (
            r"OrdinaryInoutOverlappingAccess\.swift:\d+:\d+: error: overlapping accesses to 'value', "
            r"but modification requires exclusive access"
        ),
        "StructuralSpyWrongLink": r"cannot convert value of type 'AsyncThrowingForwardingTarget<Int, Int, StructuralSpyFailure>' to expected argument type 'AsyncThrowingForwardingTarget<Int, String, StructuralSpyFailure>'",
        "SpyWrongTarget": r"argument type 'UnrelatedDependency' does not conform to expected type 'SpyDirectory'",
        "SubscriptWrongIndex": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "SubscriptWrongNewValue": r"cannot convert value of type 'Int' to expected argument type 'String'",
        "SubscriptWrongGetterResult": r"cannot convert value of type 'Int' to expected argument type 'String'",
        "SubscriptThrowForSetter": r"has no member 'willThrow'",
        "SubscriptWrongTypedError": r"cannot convert value of type 'WrongSubscriptFailure' to expected argument type 'EffectfulSubscriptFailure'",
        "SubscriptWriteReadonly": r"subscript is get-only",
        "VariadicSubscriptForwardingWrongValue": r"cannot convert value of type 'Int.Type' to expected argument type 'String.Type'",
        "VariadicSubscriptWrongIndex": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "VariadicSubscriptArraySplat": r"cannot pass array of type '\[Int\]' as variadic arguments of type 'Int'",
        "VariadicWrongElement": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "VariadicForwardingWrongArray": r"cannot convert value of type 'Int.Type' to expected argument type '\[Int\].Type'",
        "VariadicForwardingWrongError": r"invalid conversion of thrown error type 'ForeignAdapterFailure' to 'VariadicFailure'",
        "VariadicArraySplat": r"cannot pass array of type '\[Int\]' as variadic arguments of type 'Int'",
    }
    for fixture in sorted((ROOT / "Fixtures/CompileFailures").glob("*.swift")):
        compiler_stage = ["-typecheck"]
        diagnostic_patterns = [patterns[fixture.stem]]
        if fixture.stem == "ThrowingEscapingCallbackEffects":
            diagnostic_patterns.append(
                r"ThrowingEscapingCallbackEffects\.swift:12:\d+: error: .*has no member 'willThrow'"
            )
        if fixture.stem in {"InoutSpyRetainsAccess", "OrdinaryInoutRetainsAccess",
                            "OrdinaryInoutOverlappingAccess", "CallbackSpyDetachedCapture"}:
            compiler_stage = ["-emit-sil", "-o", os.devnull]
        if fixture.stem == "CallbackSpyDetachedCapture":
            diagnostic_patterns.append(r"passing closure as a 'sending' parameter risks causing data races")
        if fixture.stem in {"ConsumingInputUseAfterConsume", "ConsumingInputDuplicateTransfer", "ConsumingInputEscapedBorrow",
                           "OwnedResultCapturedReplay", "OwnedResultErasure", "OwnedResultFixedReturn",
                           "SendingRetainedInput", "SendingUseAfterTransfer", "SendingRetainedResult", "SendingFixedResult",
                           "ByteBufferDeferredAddressCapture"}:
            compiler_stage = ["-emit-sil", "-o", os.devnull]
        if fixture.stem in {"MainActorAsyncTransport", "MainActorSpyAsyncTransport"}:
            # Swift checks unsafe region transfers during SIL generation.
            compiler_stage = ["-emit-sil", "-o", os.devnull]
            payload = "DirectoryEntry" if fixture.stem == "MainActorAsyncTransport" else "ActorSpyEntry"
            diagnostic_patterns.append(rf"non-Sendable '{payload}'-typed result.*main actor-isolated")
        compiler_command = [*compiler_floor, *compiler_stage, "-I", modules]
        check_name = "compile-reject-" + fixture.stem
        run(check_name, [*compiler_command, fixture], env=swift_environment,
            fails=True, patterns=diagnostic_patterns)
        if fixture.stem in {"MainActorWitnessAccess", "MainActorStubbingAccess", "MainActorVerificationAccess",
                            "MainActorSpyWitnessAccess", "MainActorSpyAsyncTransport", "CallbackSpyDetachedCapture",
                            "ImmediateCallbackDeferredCapture", "OrdinaryInoutRetainsAccess",
                            "IsolatedActorErasedAnswer", "IsolatedActorMatcherAccess", "IsolatedActorMissingAwait",
                            "ConsumingInputUseAfterConsume", "ConsumingInputDuplicateTransfer", "ConsumingInputEscapedBorrow",
                            "OwnedResultCapturedReplay", "OwnedResultErasure", "OwnedResultFixedReturn",
                            "SendingRetainedInput", "SendingUseAfterTransfer", "SendingRetainedResult", "SendingFixedResult",
                            "ByteBufferDeferredAddressCapture",
                            "OrdinaryInoutOverlappingAccess",
                            "EscapingCallbackMainActorConversion", "MainActorEscapingCallbackNonisolatedReplay",
                            "MainActorAsyncEscapingCallbackNonisolatedReplay",
                            "MainActorThrowingEscapingCallbackWrongError",
                            "MainActorThrowingEscapingCallbackNonisolatedReplay",
                            "MainActorAsyncThrowingEscapingCallbackWrongError",
                            "MainActorAsyncThrowingEscapingCallbackNonisolatedReplay"}:
            run(check_name + "-DefaultIsolation",
                [*compiler_command, "-default-isolation", "MainActor", fixture],
                env=swift_environment, fails=True, patterns=diagnostic_patterns)
    run_swift("reporter-intentional-failure", [
        "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX022_intentionalReporterFailure"], fails=True,
        extra_environment={"BLUEPRINT_EXPECT_FAILURE": "1"},
        patterns=[r"ConsumerTests.swift:\d+", r"Expected exactly 1 calls; observed 0"])
    swift_testing_late_issue = (
        r"Cannot call schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:[^\n]+"
        r"\.set[^\n]+ in a finished mock session"
    )
    late_reporter = run_swift("swift-testing-late-reporter-ownership", [
        "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX023_lateTypeScopeTaskKeepsOwningReporter"], fails=True,
        extra_environment={"BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE": "1"},
        patterns=[swift_testing_late_issue, r"recorded an issue at TypeSubscriptDirectory\.swift:",
                  r"PASS: DX023 late type task retained its owning reporter",
                  r"Test run with 1 test.*failed.*with 1 issue\b"])
    assert len(re.findall(swift_testing_late_issue, late_reporter)) == 1

    parameterized_reporter_checks = [
        ("swift-testing-parameterized-owner-explicit", "DX023_detachedParameterizedReporterAttribution"),
    ]
    release = re.search(r"\bSwift version (\d+)\.(\d+)", compiler_version)
    if release and tuple(map(int, release.groups())) >= (6, 1):
        parameterized_reporter_checks.append(
            ("swift-testing-parameterized-owner-trait", "DX023_scopedParameterizedReporterAttribution"))
    for check, test in parameterized_reporter_checks:
        display_name = re.escape(test + "(_:)")
        issue_line = rf"(?m)^[^\n]*\bTest {display_name} recorded an issue\b[^\n]*$"
        owner_issue = (
            rf'Test {display_name} recorded an issue with 1 argument scenario\s*(?:→|->)\s*"owner-A"'
            r"\s+at TypeSubscriptDirectory\.swift:\d+:\d+: Issue recorded"
        )
        owner_started = rf'Test case passing 1 argument scenario\s*(?:→|->)\s*"owner-A" to {display_name} started\.'
        peer_started = rf'Test case passing 1 argument scenario\s*(?:→|->)\s*"peer-B" to {display_name} started\.'
        attribution = run_swift(check, [
            "test", "--package-path", "Fixtures/ProtocolConsumer", "--filter", test], fails=True,
            extra_environment={"BLUEPRINT_EXPECT_PARAMETERIZED_REPORTER_FAILURE": "1"},
            patterns=[owner_started, peer_started, owner_issue, r"PASS: DX023 owner case drained 1 detached issue",
                      r"PASS: DX023 peer case drained 0 issues",
                      rf"Test {display_name} with 2 test cases failed[^\n]+with 1 issue\.",
                      r"Test run with 1 test\b[^\n]*failed[^\n]+with 1 issue\."])
        assert len(re.findall(issue_line, attribution)) == 1, f"{check} emitted extra native issues"
        peer_id, = re.findall(r"^BLUEPRINT_PARAM_PEER_ACTIVE id=(.+)$", attribution, re.MULTILINE)
        owner_id, = re.findall(r"^BLUEPRINT_PARAM_OWNER_ACTIVE id=(.+)$", attribution, re.MULTILINE)
        assert peer_id == owner_id and test in owner_id, f"{check} did not exercise one native function"
    # The native case-boundary assertions use the event schema verified on Swift 6.4.
    if release and tuple(map(int, release.groups())) >= (6, 4):
        for context in ("inherited", "detached", "thread"):
            run(f"swift-testing-finished-owner-{context}", [
                sys.executable, "Fixtures/ProtocolConsumer/verify_closed_owner.py",
                "--swift", swift, "--evidence-dir", EVIDENCE, "--skip-build", "--context", context],
                env=swift_environment, timeout=180,
                patterns=[rf"PASS: Swift Testing closed-owner {context} produced one run-level issue and no case issues"])
        run("swift-testing-finished-owner-dropped-only", [
            sys.executable, "Fixtures/ProtocolConsumer/verify_closed_owner.py",
            "--swift", swift, "--evidence-dir", EVIDENCE, "--skip-build", "--context", "detached", "--dropped-only"],
            env=swift_environment, timeout=180,
            patterns=[r"PASS: Swift Testing closed-owner detached produced one dropped-only run-level issue and no case issues"])
    run("xctest-consumer", [sys.executable, "Fixtures/XCTestConsumer/verify.py"],
        env=swift_environment, timeout=600,
        patterns=[r"PASS: XCTest reports sync and async verification failures at their caller lines",
                  r"PASS: XCTest late type task retained its owning reporter",
                  r"PASS: XCTest routes buffered orphan failures to the suite"])
    run("quiescent-configuration-retirement", [
        modules / "consumer-demo", "--quiescent-configuration"], timeout=20,
        patterns=[r"PASS: RUN035 retired configuration reentered both locks and published the next revision",
                  r"PASS: RUN035 installed an awaited configuration through the public SwiftPM product"])
    fatal_signal = {"arm64": signal.SIGTRAP, "x86_64": signal.SIGILL}[platform.machine()]

    def run_fatal(name, flag, message, *, issue_prefix=r"^MOCK ISSUE: "):
        result = check_fatal_child(
            [modules / "consumer-demo", flag], cwd=ROOT, expected_signal=fatal_signal,
            issue_pattern=issue_prefix + message, fatal_pattern=r"^.+:\d+: Fatal error: " + message,
        )
        output = result.stderr
        if result.error is not None:
            output += f"\nVerifier: {result.error}\n"
        record_result(name, output, result.returncode, result.error is None, expected_failure=True)

    for name, flag, message in DEFAULT_VALUE_FAILURE_CASES:
        run_fatal(name, flag, message)
    missing_stubs = [
        ("typed", "--missing", r"UserRepository\|fetchUser\(id:String\) async throws\(RepositoryError\)->String"),
        ("sync", "--missing-sync", r"UserRepository\|greeting\(_:String\)->String"),
        ("never", "--missing-never", r"EffectEdges\|stop\(id:String\)->Never"),
    ]
    for label, flag, endpoint in missing_stubs:
        run_fatal(label + "-missing-terminates", flag,
                  rf"No matching stub for schema1\|ConsumerDomain\.{endpoint}\|Sendable$")
    unlisted = r"No configured specialization for schema1\|ConsumerDomain\.GenericSubscriptDirectory.*\[Swift.Bool\]$"
    run_fatal("generic-subscript-missing-terminates", "--missing-generic-specialization", unlisted)
    unlisted_method = r"No configured specialization for schema1\|ConsumerDomain\.GenericMethodDirectory\|transform<.*\[Swift.Bool\]$"
    run_fatal("generic-method-missing-terminates", "--missing-generic-method-specialization", unlisted_method)
    closed_provider = (
        r"Cannot call schema1\|ConsumerDomain\.GenericProviderDirectory\|transform<.*\[Swift.Int\] in a finished mock session$"
    )
    run_fatal("generic-provider-closed-terminates", "--closed-generic-provider", closed_provider)
    closed_rethrows = (
        r"Cannot call schema1\|ConsumerDomain\.RethrowingDirectory\|apply\(.* rethrows->String\|Sendable in a finished mock session$"
    )
    run_fatal("rethrows-provider-closed-terminates", "--closed-rethrows-provider", closed_rethrows)
    type_scope = r"Missing type-level mock scope for schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:"
    run_fatal("type-subscript-detached-reject", "--type-subscript-detached",
              type_scope + r".*\.get->Int\|Sendable$",
              issue_prefix=r"^TypeSubscriptDirectory\.swift:\d+:\d+: error: BlueprintMocking: ")
    run("type-subscript-unbound-setter", [modules / "consumer-demo", "--type-subscript-unbound-setter"],
        patterns=[type_scope + r".*\.set", r"PASS: unbound type setter returned after diagnosis"])
    stale_scope = (
        r"Cannot call schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:"
        r".*\.get->Int\|Sendable with a stale type-level mock scope$"
    )
    run_fatal("type-subscript-stale-reject", "--type-subscript-stale", stale_scope)
    closed_scope = (
        r"Cannot call schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:"
        r".*\.get->Int\|Sendable in a finished mock session$"
    )
    run_fatal("type-subscript-closed-orphan-terminates", "--type-subscript-closed-orphan", closed_scope,
              issue_prefix=r"^MOCK ORPHAN: session [0-9A-Fa-f-]+ epoch 0 TypeSubscriptDirectory\.swift:2:1: ")
    run_swift("runtime-only-consumer", [
        "run", "--package-path", "Fixtures/RuntimeOnly", "RuntimeOnly"],
        patterns=[r"PASS: runtime-only consumer"])
    runtime_bin = Path(run_swift("runtime-only-bin-path", [
        "build", "--package-path", "Fixtures/RuntimeOnly", "--show-bin-path"]).strip())
    linkage = run("runtime-only-linkage", ["otool", "-L", runtime_bin / "RuntimeOnly"])
    excluded_libraries = ("SwiftSyntax", "SwiftParser", "SourceKit", "Testing.framework", "XCTest")
    assert not any(name in linkage for name in excluded_libraries)
    dependencies = json.loads(run_swift("runtime-dependencies", ["package", "show-dependencies", "--format", "json"]))
    assert dependencies.get("dependencies") == []
    runtime_consumer = json.loads(run_swift("runtime-only-consumer-dependencies", [
        "package", "--package-path", "Fixtures/RuntimeOnly", "show-dependencies", "--format", "json"]))
    runtime_dependency, = runtime_consumer["dependencies"]
    assert runtime_dependency["name"] == "BluepringMockingFramework"
    assert runtime_dependency["dependencies"] == []
    runtime_sources = list((ROOT / "Sources/BlueprintMocking").glob("*.swift"))
    excluded_imports = ("SwiftSyntax", "SwiftParser", "SourceKit", "Testing", "XCTest")
    assert all(not any(f"import {module}" in p.read_text() for module in excluded_imports) for p in runtime_sources)

    if offline_runtime_mirror:
        run("runtime-only-offline", [
            sys.executable, "scripts/verify_offline_runtime.py", source_before["revision"],
            "--runtime-mirror", offline_runtime_mirror, "--evidence-dir", EVIDENCE,
        ], env=swift_environment, timeout=420,
            patterns=[r"PASS: runtime-only consumer resolved, built and ran from its exact mirror with networking denied",
                      r"PASS: runtime-only linkage contains only core and consumer objects",
                      r"EVIDENCE: runtime-only-offline-report\.json SHA-256 [0-9a-f]{64}"])
        run("reject-runtime-mirror-corruption", [
            sys.executable, "scripts/verify_runtime_mirror_integrity.py", source_before["revision"],
            "--runtime-mirror", offline_runtime_mirror, "--evidence-dir", EVIDENCE,
            "--valid-report", EVIDENCE / "runtime-only-offline-report.json",
        ], env=swift_environment, timeout=240,
            patterns=[r"PASS: pinned corrupt runtime mirror rejected before SwiftPM consumption and prior evidence preserved",
                      r"EVIDENCE: runtime-mirror-corruption-report\.json SHA-256 [0-9a-f]{64}"])
        run("offline-configured-generation", [
            sys.executable, "scripts/verify_offline_generation.py", source_before["revision"],
            "--runtime-mirror", offline_runtime_mirror, "--tool", tool, "--evidence-dir", EVIDENCE,
        ], env=swift_environment, timeout=420,
            patterns=[r"PASS: bundled Xcode parser generated identical shard and index bytes with networking denied",
                      r"PASS: independent configured SwiftPM consumer built and ran with networking denied",
                      r"EVIDENCE: offline-configured-generation-report\.json SHA-256 [0-9a-f]{64}"])

    if tooling_archive_mirror:
        run("tooling-archive-consumer", [
            sys.executable, "scripts/verify_tooling_archive_consumer.py", source_before["revision"],
            "--swift-syntax-mirror", tooling_archive_mirror, "--evidence-dir", EVIDENCE,
        ], env=swift_environment, timeout=240,
            patterns=[r"PASS: verified tooling archive resolved from a fresh extraction using the prepared mirror",
                      r"PASS: tampered and substituted archives rejected before toolchain selection with prior evidence preserved",
                      r"EVIDENCE: tooling-archive-consumer-report\.json SHA-256 [0-9a-f]{64}"])

    check_swiftpm_plugin = os.environ.get("BLUEPRINT_VERIFY_SWIFTPM_PLUGIN") == "1"
    if check_swiftpm_plugin:
        run("swiftpm-build-plugin-consumer", [
            sys.executable, "Fixtures/PluginConsumer/verify.py", "--swift", swift,
            "--evidence-dir", EVIDENCE, "--cache-path", ROOT / ".build/dx004-swiftpm-cache",
            "--jobs", "4",
        ], env=swift_environment, timeout=900,
            patterns=[r"PASS: DX004 SwiftPM plugin clean build, regeneration, and incremental stability"])
    check_configured_binding_plugin = os.environ.get("BLUEPRINT_VERIFY_CONFIGURED_BINDING_PLUGIN") == "1"
    if check_configured_binding_plugin:
        run("swiftpm-configured-binding-plugin", [
            sys.executable, "Fixtures/PluginConsumer/verify_associated_binding.py", "--swift", swift,
            "--host-tool", tool, "--evidence-dir", EVIDENCE, "--jobs", "4",
        ], env=swift_environment, timeout=300,
            patterns=[r"PASS: GEN008 configured binding compiled and ran through the SwiftPM build plugin"])
    check_explicit_conditional_consumer = os.environ.get("BLUEPRINT_VERIFY_CONDITIONAL_CONSUMER") == "1"
    if check_explicit_conditional_consumer:
        run("swiftpm-explicit-conditional-consumer", [
            sys.executable, "Fixtures/ConditionalConsumer/verify.py", "--swift", swift,
            "--tool", tool, "--evidence-dir", EVIDENCE, "--jobs", "4",
        ], env=swift_environment, timeout=400,
            patterns=[r"PASS: GEN004-A explicit domain conditions select native SwiftPM witnesses"])
    source_after = checkout_state()
    exact_revision = (
        source_before["revision"]
        if source_before and source_before == source_after and source_before["clean"] else None
    )
    profile = {
        "sourceRevision": exact_revision,
        "checkoutBefore": source_before,
        "checkoutAfter": source_after,
        "resultsSHA256": hashlib.sha256(result_document()).hexdigest(),
        "status": "prototype evidence, not release certification",
        "swift": swift_version,
        "swiftPath": str(swift),
        "swiftCompilerVersion": compiler_version,
        "swiftCompilerPath": str(swiftc),
        "languageMode": "6", "sdkPath": sdk,
        "sdkVersion": sdk_version,
        "executionOS": subprocess.check_output(["sw_vers"], text=True).strip(),
        "architecture": platform.machine(), "deploymentTarget": f"macOS {deployment_target}",
        "defaultIsolation": "compiler default (nonisolated); no upcoming feature flags",
        "parser": "SwiftParser/SwiftSyntax bundled with this exact Xcode toolchain",
        "swiftPMOfflineRuntimeVerified": bool(offline_runtime_mirror),
        "swiftPMBuildPluginVerified": check_swiftpm_plugin,
        "swiftPMToolingArchiveConsumerVerified": bool(tooling_archive_mirror),
        "swiftPMExplicitConditionalConsumerVerified": check_explicit_conditional_consumer,
        "swiftPMConfiguredBindingPluginVerifiedWithBundledParser": check_configured_binding_plugin,
        "generatedSHA256": hashlib.sha256(baseline).hexdigest(),
        "inheritedProtocolGeneratedSHA256": hashlib.sha256(inherited_mock.encode()).hexdigest(),
        "mainActorGeneratedSHA256": hashlib.sha256(actor_baseline).hexdigest(),
        "effectsGeneratedSHA256": hashlib.sha256(effect_generated.read_bytes()).hexdigest(),
        "effectEdgesGeneratedSHA256": hashlib.sha256(edge_generated.read_bytes()).hexdigest(),
        "parameterListGeneratedSHA256": hashlib.sha256(parameter_generated.read_bytes()).hexdigest(),
        "structuralTypesGeneratedSHA256": hashlib.sha256(structural_generated.read_bytes()).hexdigest(),
        "propertyAccessorsGeneratedSHA256": hashlib.sha256(property_generated.read_bytes()).hexdigest(),
        "subscriptGeneratedSHA256": hashlib.sha256(subscript_generated.read_bytes()).hexdigest(),
        "effectfulSubscriptGeneratedSHA256": hashlib.sha256(effectful_subscript_generated.read_bytes()).hexdigest(),
        "actorSpyGeneratedSHA256": hashlib.sha256(actor_spy_generated.read_bytes()).hexdigest(),
        "spyGeneratedSHA256": hashlib.sha256(spy_generated.read_bytes()).hexdigest(),
        "typeSubscriptGeneratedSHA256": hashlib.sha256(type_subscript_generated.read_bytes()).hexdigest(),
        "genericSubscriptGeneratedSHA256": hashlib.sha256(generic_subscript_generated.read_bytes()).hexdigest(),
        "variadicSubscriptGeneratedSHA256": hashlib.sha256(variadic_subscript_generated.read_bytes()).hexdigest(),
        "variadicGeneratedSHA256": hashlib.sha256(variadic_generated.read_bytes()).hexdigest(),
        "acceptanceContractCount": len(rows),
    }
    (EVIDENCE / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")

def cli():
    global EVIDENCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-checks-only", action="store_true",
                        help="run the SYS-008 evaluator checks without building Swift targets")
    args = parser.parse_args()
    if args.release_checks_only and "BLUEPRINT_EVIDENCE_DIRECTORY" not in os.environ:
        EVIDENCE = EVIDENCE / "release-checks"
    EVIDENCE.mkdir(parents=True, exist_ok=True)

    exit_status = 0
    try:
        if args.release_checks_only:
            verify_local_release_checks()
        else:
            main()
    except Exception as error:
        print("Verification failed: " + str(error), file=sys.stderr)
        exit_status = 1
    finally:
        if not args.release_checks_only:
            (EVIDENCE / "results.json").write_bytes(result_document())
    if exit_status == 0:
        if args.release_checks_only:
            print(f"Local release checks passed; evidence is in {EVIDENCE / 'release-checks.json'}.", flush=True)
        else:
            print(f"All prototype checks passed; evidence is in {EVIDENCE / 'results.json'}.", flush=True)
    return exit_status


if __name__ == "__main__":
    sys.exit(cli())
