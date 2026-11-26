#!/usr/bin/env python3
"""Compare independently built Xcode-host and pinned SwiftPM-static generators."""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

from check_release import read_json
from export_tooling import git, load_manifest, tracked_entries
from verify_inspection import OUTPUT_NAMES, snapshot
from verify_offline_generation import (
    DYLD_IMAGE, PARSER_LIBRARIES, read_generated, sha256, validate_generated_outputs, validate_parser_trace,
)
from verify_offline_runtime import NETWORK_BLOCK, NETWORK_PROFILE, offline_git_environment, probe_network
from verify_remote_install import swift_toolchain, validate_revision


ROUTES = ("bundled", "packaged")
REPORT = "parser-parity-report.json"
DOMAIN = "Fixtures/ProtocolConsumer/Sources/ConsumerDomain"
INHERITED = ("InheritedDirectory", "InheritedDirectoryRoot",
             "InheritedDirectoryReadBranch", "InheritedDirectoryWriteBranch")
MISSING_PARENT = (
    b"InheritedDirectory.swift:1:37: error: BPM001: Missing inherited protocol "
    b"ConsumerDomain.InheritedDirectoryReadBranch in the supplied source inputs\n"
)
CONFLICTING_ELEMENT = (
    b"CursorSequence.swift:3:76: error: BPM001: Dependent same-type constraint 'Iterator.Element == Element' "
    b"requires matching types. ConsumerDomain.IntCursor.Element is Swift.Int at IntCursor.swift:2:5 "
    b"and Element is Swift.String\n"
)


@dataclass(frozen=True)
class Case:
    name: str
    diagnostic: bytes | None = None


@dataclass(frozen=True)
class Observation:
    exit: int
    stdout: bytes
    stderr: bytes
    outputs: dict[str, bytes]


def qualify_cases(cases, invoke, report_path, provenance):
    report_path.unlink(missing_ok=True)
    comparisons = {}
    for case in cases:
        bundled, packaged = (invoke(case, route) for route in ROUTES)
        if bundled != packaged:
            differences = [field for field in ("exit", "stdout", "stderr", "outputs")
                           if getattr(bundled, field) != getattr(packaged, field)]
            raise ValueError(f"{case.name}: parser parity mismatch in {', '.join(differences)}")
        if case.diagnostic is None:
            if (bundled.exit != 0 or bundled.stderr or bundled.outputs.keys() != set(OUTPUT_NAMES)
                    or not all(bundled.outputs.values())):
                raise ValueError(f"{case.name}: expected exactly two successful generated outputs")
        elif bundled.exit != 1 or bundled.stdout or bundled.stderr != case.diagnostic:
            raise ValueError(f"{case.name}: expected exit 1 and the exact rejection diagnostic")

        comparisons[case.name] = {
            "exit": bundled.exit,
            "stdout": bundled.stdout.decode("utf-8"),
            "diagnostic": bundled.stderr.decode("utf-8"),
            "matchedOutputSHA256": {name: hashlib.sha256(data).hexdigest()
                                    for name, data in sorted(bundled.outputs.items())},
        }
    report_path.write_text(json.dumps({"status": "passed", **provenance, "cases": comparisons}, indent=2) + "\n")


def verify_checkout(root, revision, scope):
    head = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    top = Path(os.fsdecode(git(root, "rev-parse", "--show-toplevel").strip())).resolve()
    status = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all").split(b"\0")
    allowed = {b"", b"?? Packages/Tooling/Package.resolved"} if scope == "Packages/Tooling" else {b""}
    if head != revision or top != root or set(status).difference(allowed):
        raise ValueError(f"Expected a clean build checkout of {revision} at {root}")
    records = git(root, "ls-tree", "-rz", "--full-tree", revision, "--", scope)
    tracked = set()
    for record in records.rstrip(b"\0").split(b"\0"):
        header, name = record.split(b"\t", 1)
        mode, kind, blob = header.split()
        path = root / os.fsdecode(name)
        if mode not in (b"100644", b"100755") or kind != b"blob" or path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular tracked build input: {path}")
        contents = path.read_bytes()
        raw = f"blob {len(contents)}\0".encode("ascii") + contents
        if hashlib.sha1(raw).hexdigest().encode("ascii") != blob:
            raise ValueError(f"Packaged build checkout differs from the committed bytes: {path}")
        tracked.add(path)
    sources = root / ("Sources" if scope == "." else f"{scope}/Sources")
    if not set(sources.rglob("*.swift")).issubset(tracked):
        raise ValueError(f"Untracked compiler input under {sources}")
    return hashlib.sha256(records).hexdigest()


def verify_receipt(path, common, route, binary, additional):
    receipt = read_json(path.read_bytes(), f"{route} build receipt")
    expected = common | additional | {"schema": 1, "route": route, "executableSHA256": sha256(binary)}
    if type(receipt.get("schema")) is not int or receipt != expected:
        raise ValueError(f"{route}: build receipt does not match the selected revision, toolchain or artifacts")
    return receipt


def inspect_provenance(args, environment, artifacts):
    if sys.platform != "darwin":
        raise ValueError("Parser provenance checks currently require macOS Mach-O and dyld tools")
    validate_revision(args.revision)
    if args.bundled_tool.samefile(args.packaged_tool) or sha256(args.bundled_tool) == sha256(args.packaged_tool):
        raise ValueError("Expected two independent binaries, not a self-comparison")
    if not all(os.access(tool, os.X_OK) for tool in (args.bundled_tool, args.packaged_tool)):
        raise ValueError("Both generator paths must be executable")
    compiler = Path(environment["SWIFT_EXEC"])
    compiler_version = subprocess.check_output([str(compiler), "--version"], env=environment, text=True).strip()
    common = {"sourceRevision": args.revision, "swiftCompiler": str(compiler),
              "compilerVersion": compiler_version, "sdk": environment["SDKROOT"]}
    host = compiler.parent.parent / "lib/swift/host"
    dylibs = {name: (host / name).resolve(strict=True) for name in sorted(PARSER_LIBRARIES)}
    bundled = verify_receipt(args.bundled_receipt, common, "bundled", args.bundled_tool,
                             {"parserSHA256": {name: sha256(path) for name, path in dylibs.items()}})

    _, compatibility = load_manifest(args.repository, tracked_entries(args.repository, args.revision))
    syntax = compatibility["swiftSyntax"]
    lock = read_json(args.package_resolved.read_bytes(), "packaged SwiftPM lockfile")
    pins = lock.get("pins")
    if (not isinstance(pins, list) or len(pins) != 1
            or pins[0].get("identity") != "swift-syntax" or pins[0].get("location") != syntax["url"]
            or pins[0].get("kind") not in ("localSourceControl", "remoteSourceControl")
            or pins[0].get("state") != {"revision": syntax["revision"], "version": syntax["version"]}):
        raise ValueError("The packaged SwiftPM lockfile must resolve the committed SwiftSyntax pin")
    linkfile = args.packaged_tool.parent / "blueprint-mocking.product/Objects.LinkFileList"
    if (not args.packaged_tool.is_relative_to(args.package_scratch)
            or not args.syntax_checkout.is_relative_to(args.package_scratch / "checkouts")):
        raise ValueError("Keep the packaged executable and pinned checkout in their native SwiftPM scratch directory")

    packaged = verify_receipt(args.packaged_receipt, common, "packaged", args.packaged_tool, {
        "packageResolvedSHA256": sha256(args.package_resolved),
        "linkFileListSHA256": sha256(linkfile),
    })
    targets = set()
    for line in linkfile.read_text().splitlines():
        names = shlex.split(line) if line.startswith(("'", '"')) else [line]
        if len(names) != 1:
            raise ValueError("Malformed packaged SwiftPM link input")
        path = Path(names[0]).resolve(strict=True)
        if not path.is_relative_to(args.package_scratch) or path.suffix != ".o":
            raise ValueError(f"Unapproved packaged link input: {path}")
        targets.add(path.parent.name)
    if not {"SwiftParser.build", "SwiftSyntax.build", "BlueprintMockingCLI.build"}.issubset(targets):
        raise ValueError("The packaged executable must link objects from both pinned parser targets")

    source_hash = verify_checkout(args.package_checkout, args.revision, "Packages/Tooling")
    syntax_hash = verify_checkout(args.syntax_checkout, syntax["revision"], ".")
    linkage = subprocess.check_output(["/usr/bin/otool", "-L", str(args.packaged_tool)], env=environment)
    if any(name.encode("ascii") in linkage for name in PARSER_LIBRARIES):
        raise ValueError("The packaged executable imports a dynamic parser library")
    symbols = subprocess.check_output(["/usr/bin/nm", "-U", "-j", str(args.packaged_tool)], env=environment)
    for module in (b"SwiftParser", b"SwiftSyntax"):
        if not re.search(rb"(?m)^_\$s11" + module + rb"[^\n]+$", symbols):
            raise ValueError(f"The packaged executable lacks defined {module.decode()} symbols")
    for name, data in (("packaged-linkage.log", linkage), ("packaged-defined-symbols.log", symbols)):
        (args.evidence_dir / name).write_bytes(data)
        artifacts[name] = hashlib.sha256(data).hexdigest()

    return dylibs, {
        "sourceRevision": args.revision,
        "comparison": "configured shard/index bytes and exact diagnostic/exit parity",
        "bundled": bundled,
        "packaged": packaged,
        "bundledLibraryPaths": {name: str(path) for name, path in dylibs.items()},
        "packagedSwiftSyntax": syntax,
        "packagedToolingSourceInventorySHA256": source_hash,
        "swiftSyntaxSourceInventorySHA256": syntax_hash,
        "artifacts": artifacts,
    }


def make_corpus():
    def selection(module, name, **extra):
        return {"module": module, "type": name, "kind": "protocol", **extra}

    inherited = {f"{name}.swift": ("ConsumerDomain", f"{DOMAIN}/{name}.swift") for name in INHERITED}
    iterator = {f"{name}.swift": ("ConsumerDomain", f"{DOMAIN}/{name}.swift")
                for name in ("CursorSequence", "IntCursor")}
    iterator_binding = {"associatedTypeBindings": [{"name": "Iterator", "type": "ConsumerDomain.IntCursor"}]}
    return (
        (Case("typed-lookup"), selection("OfflineDomain", "Lookup"),
         {"Lookup.swift": ("OfflineDomain", "Fixtures/OfflineGenerationConsumer/Sources/OfflineDomain/Lookup.swift")}),
        (Case("inherited-diamond"), selection("ConsumerDomain", "InheritedDirectory"), inherited),
        (Case("dependent-iterator"), selection("ConsumerDomain", "IntSequence", **iterator_binding),
         iterator | {"IntSequence.swift": ("ConsumerDomain", f"{DOMAIN}/IntSequence.swift")}),
        (Case("missing-parent", MISSING_PARENT), selection("ConsumerDomain", "InheritedDirectory"),
         {name: origin for name, origin in inherited.items() if name != "InheritedDirectoryReadBranch.swift"}),
        (Case("conflicting-element", CONFLICTING_ELEMENT),
         selection("ConsumerDomain", "StringCursorSequence", **iterator_binding),
         iterator | {"StringCursorSequence.swift": (
             "ConsumerDomain", "Fixtures/InheritanceRejections/StringCursorSequence.swift")}),
    )


def normalize_diagnostic(stderr, directory):
    lines = []
    for line in stderr.splitlines(keepends=True):
        text = line.rstrip(b"\r\n")
        if DYLD_IMAGE.fullmatch(text) or re.fullmatch(rb"dyld\[[0-9]+\]: move loaded to delayed: [^\r\n]+", text):
            continue
        lines.append(line)
    return b"".join(lines).replace(os.fsencode(str(directory) + "/"), b"")


def execute_corpus(repository, revision, tools, environment, dylibs, evidence, provenance):
    requests = make_corpus()
    metadata = {}
    provenance["requests"] = metadata
    baseline = None
    with tempfile.TemporaryDirectory(prefix="Parser Parity ", dir=evidence) as temporary:
        root = Path(temporary)
        configurations = {}
        for case, selection, inputs in requests:
            directory = root / case.name
            directory.mkdir()
            configuration = directory / "blueprint-mocking.json"
            configuration.write_text(json.dumps({"schemaVersion": 1, "selections": [selection]}))
            arguments = ["--config", str(configuration), "--output", str(directory / "Generated"),
                         "--input-set-id", "92"]
            hashes = {}
            for name, (module, source) in sorted(inputs.items()):
                path = directory / name
                path.write_bytes(git(repository, "show", f"{revision}:{source}"))
                hashes[source] = sha256(path)
                arguments.extend(["--source", module, str(path)])
            configurations[case.name] = directory, arguments
            metadata[case.name] = {"selection": selection, "sourceSHA256": hashes,
                                   "configurationSHA256": sha256(configuration), "inputSetID": "92"}

        def invoke(case, route):
            nonlocal baseline
            directory, arguments = configurations[case.name]
            output = directory / "Generated"
            if output.exists():
                shutil.rmtree(output)
            before = None
            if case.diagnostic is not None:
                if baseline is None:
                    raise ValueError("A valid output pair must precede rejected cases")
                output.mkdir()
                for name, data in baseline.items():
                    (output / name).write_bytes(data)
                before = snapshot(output)
            result = subprocess.run(
                NETWORK_BLOCK + ["/usr/bin/env", "DYLD_PRINT_LIBRARIES=1", str(tools[route]), "generate", *arguments],
                env=environment, capture_output=True, timeout=90,
            )
            for channel, data in (("stdout", result.stdout), ("stderr", result.stderr)):
                path = evidence / f"{case.name}-{route}.{channel}"
                path.write_bytes(data)
                provenance["artifacts"][path.name] = sha256(path)
            if route == "bundled":
                validate_parser_trace(result.stderr, dylibs)
            else:
                images = DYLD_IMAGE.findall(result.stderr)
                if not images or any(Path(os.fsdecode(path)).name in PARSER_LIBRARIES for path in images):
                    raise ValueError("Need a packaged loader trace without dynamic parser images")

            diagnostic = normalize_diagnostic(result.stderr, directory)
            if before is not None and (not output.is_dir() or snapshot(output) != before):
                raise ValueError(f"{case.name}/{route}: rejected generation changed prior outputs")
            files = read_generated(output) if output.is_dir() else {}
            if case.diagnostic is None and result.returncode == 0:
                validate_generated_outputs(files, files, input_set="92")
                if route == "bundled":
                    baseline = files
            return Observation(result.returncode, result.stdout, diagnostic, files)

        qualify_cases([case for case, _, _ in requests], invoke, evidence / REPORT, provenance)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision", help="Exact authoring revision shared by both builds")
    for flag in ("bundled-tool", "bundled-receipt", "packaged-tool", "packaged-receipt",
                 "package-checkout", "package-scratch", "package-resolved", "syntax-checkout", "evidence-dir"):
        parser.add_argument("--" + flag, type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        args.evidence_dir = args.evidence_dir.resolve()
        args.evidence_dir.mkdir(parents=True, exist_ok=True)
        report = args.evidence_dir / REPORT
        report.unlink(missing_ok=True)
        for name, path in vars(args).items():
            if isinstance(path, Path):
                setattr(args, name, path.resolve(strict=True))
        _, inherited = swift_toolchain()
        environment = {key: value for key, value in offline_git_environment(inherited).items()
                       if not key.startswith("DYLD_")}
        dylibs, provenance = inspect_provenance(args, environment, {})
        provenance["networkPolicy"] = NETWORK_PROFILE
        provenance["networkProbe"] = probe_network(environment)
        execute_corpus(args.repository, args.revision,
                       {"bundled": args.bundled_tool, "packaged": args.packaged_tool},
                       environment, dylibs, args.evidence_dir, provenance)
        print("PASS: independently built bundled and packaged generators agree on the parity corpus")
        print(f"EVIDENCE: {report.name} SHA-256 {sha256(report)}")
        return 0
    except (OSError, AttributeError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Parser parity verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
