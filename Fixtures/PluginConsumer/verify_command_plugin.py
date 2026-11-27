#!/usr/bin/env python3
"""Qualify split-permission command plugins through the native macOS SwiftPM host."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


TOOLING = Path("Packages/Tooling")
TOOL = "BlueprintMockingCLI"
READ = "blueprint-mocking-read"
WRITE = "blueprint-mocking-generate"
OUTPUTS = ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")
ARTIFACT = f'{TOOL}.artifactbundle'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def authored_state(package):
    return {
        str(path.relative_to(package)): (path.stat().st_mtime_ns, digest(path))
        for path in package.rglob("*")
        if path.is_file() and not path.is_symlink()
    }


def stage(repository, scratch, tool, triple):
    consumer = scratch / "Consumer With Spaces"
    provider = scratch / "Tool Provider"
    provider.mkdir()
    manifest = (repository / TOOLING / "Package.swift").read_text(encoding="utf-8")
    # Preserve the production product/permission declarations and replace only the
    # source-built executable with the prepared host artifact.
    manifest, dependency_count = re.subn(r"    dependencies: \[\n.*?\n    \],\n", "", manifest,
                                           count=1, flags=re.DOTALL)
    manifest, target_count = re.subn(r"        \.executableTarget\(\n.*?\n        \),",
                                     f'        .binaryTarget(name: "{TOOL}", path: "{ARTIFACT}"),',
                                     manifest, count=1, flags=re.DOTALL)
    if (dependency_count, target_count) != (1, 1):
        raise ValueError("Could not isolate the host artifact from the tooling manifest")
    (provider / "Package.swift").write_text(manifest, encoding="utf-8")
    shutil.copytree(repository / TOOLING / "Plugins", provider / "Plugins")
    bundle = provider / ARTIFACT
    executable = bundle / "macos" / TOOL
    executable.parent.mkdir(parents=True)
    shutil.copy2(tool, executable)
    info = {"schemaVersion": "1.0", "artifacts": {TOOL: {
        "type": "executable", "version": "1.0.0",
        "variants": [{"path": f"macos/{TOOL}", "supportedTriples": [triple]}],
    }}}
    (bundle / "info.json").write_text(json.dumps(info) + "\n", encoding="utf-8")
    source = consumer / "Sources" / "Domain" / "Lookup With Spaces.swift"
    source.parent.mkdir(parents=True)
    source.write_text("public protocol Lookup: Sendable { func find(_ key: String) -> String }\n",
                      encoding="utf-8")
    (consumer / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "CommandPluginConsumer",\n'
        '    dependencies: [.package(path: "../Tool Provider")], targets: [.target(name: "Domain")])\n',
        encoding="utf-8",
    )
    (consumer / "blueprint-mocking.json").write_text(
        json.dumps({"schemaVersion": 1, "selections": [
            {"module": "Domain", "type": "Lookup", "kind": "protocol"}
        ]}) + "\n", encoding="utf-8",
    )
    plugin_sources = sorted((provider / "Plugins").rglob("*.swift"))
    return consumer, executable, {
        "executableSHA256": digest(executable),
        "pluginSHA256": {str(path.relative_to(provider)): digest(path) for path in plugin_sources},
    }


def verify(repository, swift, tool, evidence):
    info = json.loads(subprocess.check_output([swift, "-print-target-info"], timeout=30))
    triple = info["target"]["unversionedTriple"]
    if not triple.endswith("-apple-macosx"):
        raise ValueError("This fixture expects the macOS SwiftPM command host")
    records = {}

    with tempfile.TemporaryDirectory(prefix="Command Plugin ", dir=evidence) as directory:
        scratch = Path(directory)
        consumer, executable, artifacts = stage(repository, scratch, tool, triple)
        authored = authored_state(consumer)
        host = [swift, "package", "--package-path", str(consumer),
                "--scratch-path", str(scratch / "Host Products"), "plugin"]
        environment = os.environ.copy()
        environment["GIT_ALLOW_PROTOCOL"] = "file"
        generated = "Generated $(verbatim)"
        args = ["--config", "blueprint-mocking.json", "--output", generated,
                "--input-set-id", "c006", "--source", "Domain", "Sources/Domain/Lookup With Spaces.swift"]
        output = consumer / generated

        def run(label, command, *, status=0, diagnostic=None):
            result = subprocess.run(
                command, cwd=consumer, env=environment, stdin=subprocess.DEVNULL,
                capture_output=True, timeout=90, text=True, errors="replace",
            )
            for stream in ("stdout", "stderr"):
                (evidence / f"{label}.{stream}.log").write_text(getattr(result, stream), encoding="utf-8")
            success = result.returncode == status if status is not None else result.returncode != 0
            combined = result.stdout + result.stderr
            if not success or (diagnostic and not re.search(diagnostic, combined, flags=re.IGNORECASE)):
                raise ValueError(f"{label}: expected status {status} and diagnostic {diagnostic!r}, "
                                 f"got {result.returncode}. See {label}.stdout.log and .stderr.log")
            records[label] = {str(name): digest(evidence / name) for name in (
                f"{label}.stdout.log", f"{label}.stderr.log"
            )}
            records[label]["status"] = result.returncode
            print(f"PASS: SwiftPM command plugin {label}", flush=True)
            return combined

        def package_untouched():
            if authored_state(consumer) != authored:
                raise ValueError("Read-only or denied command changed the package")

        plugin_list = run("command-discovery", [*host, "--list"])
        if READ not in plugin_list or WRITE not in plugin_list:
            raise ValueError("Native SwiftPM did not discover both Blueprint Mocking command verbs")

        direct = run("canonical-inspect", [str(executable), "inspect", *args, "--format", "json"])
        inspected = run("inspect-without-write-permission", [*host, READ, "inspect", *args, "--format", "json"])
        # SwiftPM may include its own contextual lines, such as progress.
        if direct.strip() not in inspected or json.loads(direct)["declarations"][0]["type"] != "Lookup":
            raise ValueError("Native inspection did not return the canonical resolved declaration JSON")
        package_untouched()

        mismatch = run("missing-checked-in-mocks", [*host, READ, "verify-generated", *args], status=None,
                       diagnostic=r"BPM003: Generated files differ")
        if "status 3" not in mismatch:
            raise ValueError("The command plugin did not relay canonical drift status 3")
        package_untouched()

        run("read-verb-refuses-write-operation", [*host, READ, "generate", *args], status=None,
            diagnostic=r"inspect.*verify-generated")
        package_untouched()

        denied = run("denied-package-write", [*host, WRITE, *args], status=None,
                     diagnostic=r"(?:requires|wants) permission to write to the package directory")
        if "Blueprint Mocking invocation:" in denied or output.exists():
            raise ValueError("SwiftPM ran generation without permission")
        package_untouched()

        grant = [*host, "--allow-writing-to-package-directory", WRITE]
        allowed = run("approved-generate-with-spaces", [*grant, *args], diagnostic=r"generated 1 protocol mock")
        if not output.is_dir() or sorted(path.name for path in output.iterdir()) != sorted(OUTPUTS):
            raise ValueError("Approved generation did not produce the two fixed files")
        invocation_line = next((line for line in allowed.splitlines()
                                if line.startswith("Blueprint Mocking invocation: ")), None)
        if invocation_line is None:
            raise ValueError("The plugin did not record the resolved canonical invocation")
        invocation = json.loads(invocation_line.removeprefix("Blueprint Mocking invocation: "))
        recorded = ["generate", *args]
        recorded[4] = str(output.resolve())
        if invocation["arguments"] != recorded or Path(invocation["workingDirectory"]) != consumer.resolve():
            raise ValueError("The recorded CLI argv lost a path or did not resolve its destination inside the package")
        direct_output = scratch / "Direct Generator"
        direct_args = args.copy()
        direct_args[3] = str(direct_output)
        run("canonical-generate", [str(executable), "generate", *direct_args])
        if any((output / name).read_bytes() != (direct_output / name).read_bytes() for name in OUTPUTS):
            raise ValueError("The command plugin generated different bytes from the canonical CLI")
        stable = authored_state(consumer)

        run("verify-without-write-permission", [*host, READ, "verify-generated", *args],
            diagnostic=r"verified 2 generated file")
        if authored_state(consumer) != stable:
            raise ValueError("A passing check changed the package")

        shard = output / OUTPUTS[0]
        shard.write_text(shard.read_text(encoding="utf-8") + "// changed in fixture\n", encoding="utf-8")
        changed = authored_state(consumer)
        run("check-reports-drift-without-repair", [*host, READ, "verify-generated", *args], status=None,
            diagnostic=r"BPM003: Generated files differ")
        run("existing-destination-refused", [*grant, *args], status=None,
            diagnostic=r"new package-relative output directory")
        if authored_state(consumer) != changed:
            raise ValueError("A failed check or existing-destination refusal changed the package")

        invalid = args.copy()
        invalid[1] = "missing-config.json"
        invalid[3] = "Invalid Reservation"
        run("invalid-input-removes-empty-reservation", [*grant, *invalid], status=None,
            diagnostic=r"Blueprint Mocking CLI ended with status 1")
        if (consumer / invalid[3]).exists() or authored_state(consumer) != changed:
            raise ValueError("Invalid CLI inputs left an empty output reservation or changed authored files")

        unowned = consumer / "Unowned"
        unowned.mkdir()
        sentinel = unowned / OUTPUTS[0]
        sentinel.write_text("// independently authored Swift\n", encoding="utf-8")
        unrelated = authored_state(consumer)
        unowned_args = args.copy()
        unowned_args[3] = str(unowned.relative_to(consumer))
        run("unowned-output-preserved", [*grant, *unowned_args], status=None,
            diagnostic=r"new package-relative output directory")
        if authored_state(consumer) != unrelated:
            raise ValueError("Refusal changed an unowned file")

        for label, bad_destination in (
            ("outside-traversal", "../Forbidden"), ("absolute-destination", str(scratch / "Forbidden"))
        ):
            outside = args.copy()
            outside[3] = bad_destination
            run(label, [*grant, *outside], status=None, diagnostic=r"package-relative")
        (consumer / "External Link").symlink_to(scratch, target_is_directory=True)
        linked = args.copy()
        linked[3] = "External Link/Forbidden"
        run("symlinked-parent-refused", [*grant, *linked], status=None, diagnostic=r"symbolic link")
        if (scratch / "Forbidden").exists() or authored_state(consumer) != unrelated:
            raise ValueError("Rejected output paths changed files")

        return {"hostTriple": triple, "compilerVersion": info["compilerVersion"],
                "artifacts": artifacts, "steps": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--host-tool", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    options = parser.parse_args()
    options.evidence_dir.mkdir(parents=True, exist_ok=True)
    try:
        report = verify(options.repository.resolve(strict=True), str(options.swift.absolute()),
                        options.host_tool.absolute(), options.evidence_dir.resolve())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
    report_path = options.evidence_dir / "swiftpm-command-plugin-report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("PASS: Native SwiftPM command plugin permission separation and canonical output parity")
    print(f"EVIDENCE: {report_path.name} SHA-256 {digest(report_path)}")


if __name__ == "__main__":
    main()
